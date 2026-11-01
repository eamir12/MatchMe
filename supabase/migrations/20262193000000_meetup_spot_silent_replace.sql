-- Spot me: replacing your live card is immediate and silent.
--
-- Before this migration any share within 60 seconds of the previous row was
-- rejected (meetup_spot_rate_limited), and every insert alerted the partner
-- again. A sender can only ever hold one live card per match, so a second
-- share is a replacement, not a second announcement:
--   * the 60-second cooldown now gates only the first card (no live card);
--   * a replacement soft-deletes the previous live row and inserts the new one
--     without an inbox row, push or heads-up banner. The partner still sees
--     the new card through the meetup_spot_cards realtime subscription.
--
-- "Same meet-up" is the live-card window (meetup.spot_card_expiry_minutes,
-- default 120 min) — while your card is live, changes are silent.
--
-- The replaced row stays soft-deleted, so the existing photo cleanup
-- (spotPathsForMatch(onlyInactive) on either device) still purges the old
-- object.
--
-- Suppression uses the transaction-local GUC meetup.spot_replace_silent, read
-- by notify_meetup_spot(). The legacy session-keyed meetup_spot_share() does
-- not set it and keeps alerting installed builds.
--
-- Apply order matters: notify_meetup_spot() is recreated below with the
-- 20262191000000 actor-name body, so this file must be applied after it.

-- ---------------------------------------------------------------------------
-- 1. Share / replace
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.meetup_spot_share_for_match(
  p_match_id UUID,
  p_storage_path TEXT,
  p_kind TEXT,
  p_outfit JSONB DEFAULT '{}'::jsonb,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_card public.meetup_spot_cards%ROWTYPE;
  v_count INTEGER;
  v_replacing BOOLEAN;
  v_recent BOOLEAN;
  v_note TEXT;
  v_spot_minutes INT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'meetup_auth_required';
  END IF;
  IF p_match_id IS NULL OR NOT public.meetup_match_participant(p_match_id) THEN
    RAISE EXCEPTION 'meetup_not_participant';
  END IF;

  IF p_kind IS NULL OR p_kind NOT IN ('self', 'meeting_point') THEN
    RAISE EXCEPTION 'meetup_invalid_spot_kind';
  END IF;

  IF p_outfit IS NOT NULL AND (
       jsonb_typeof(p_outfit) <> 'object'
       OR char_length(p_outfit::text) > 2000
     ) THEN
    RAISE EXCEPTION 'meetup_invalid_spot_outfit';
  END IF;

  -- A card may contain only outfit details/note and no photo at all.
  -- Compare folders exactly; LIKE would treat the "_" in "m_" as a wildcard.
  p_storage_path := COALESCE(btrim(p_storage_path), '');
  IF char_length(p_storage_path) > 512 THEN
    RAISE EXCEPTION 'meetup_invalid_spot_path';
  END IF;
  IF p_storage_path <> '' AND (
       split_part(p_storage_path, '/', 1) <> 'm_' || p_match_id::text
       OR split_part(p_storage_path, '/', 2) <> v_uid::text
       OR split_part(p_storage_path, '/', 3) = ''
     ) THEN
    RAISE EXCEPTION 'meetup_invalid_spot_path';
  END IF;

  -- The cap counts live cards only; old expired cards must not lock the tools
  -- for the lifetime of the match.
  SELECT count(*) INTO v_count
  FROM public.meetup_spot_cards
  WHERE match_id = p_match_id
    AND sender_id = v_uid
    AND deleted_at IS NULL
    AND expires_at > now();
  IF v_count >= 5 THEN
    RAISE EXCEPTION 'meetup_spot_limit';
  END IF;

  -- A live card makes this share a replacement: allowed immediately and
  -- without a second alert. Only a fresh announcement is rate limited.
  v_replacing := v_count > 0;
  IF NOT v_replacing THEN
    SELECT EXISTS (
      SELECT 1 FROM public.meetup_spot_cards
      WHERE match_id = p_match_id
        AND sender_id = v_uid
        AND created_at > now() - interval '60 seconds'
    ) INTO v_recent;
    IF v_recent THEN
      RAISE EXCEPTION 'meetup_spot_rate_limited';
    END IF;
  END IF;

  v_note := NULLIF(btrim(COALESCE(p_note, '')), '');
  IF v_note IS NOT NULL AND char_length(v_note) > 280 THEN
    v_note := left(v_note, 280);
  END IF;

  -- The client's alert-bar TTL reads meetup.spot_card_expiry_minutes, so the
  -- stored expiry must be computed from the same key (non-numeric values
  -- fall back to the default).
  v_spot_minutes := GREATEST(COALESCE((
    SELECT CASE WHEN jsonb_typeof(config_value) = 'number'
                THEN (config_value #>> '{}')::int END
    FROM public.app_config
    WHERE config_key = 'meetup.spot_card_expiry_minutes'
  ), 120), 1);

  -- One live card per sender and match: the previous one is superseded.
  UPDATE public.meetup_spot_cards
  SET deleted_at = now()
  WHERE match_id = p_match_id
    AND sender_id = v_uid
    AND deleted_at IS NULL;

  IF v_replacing THEN
    -- Read by notify_meetup_spot(); local to this transaction so the legacy
    -- RPC and any other insert keep alerting.
    PERFORM set_config('meetup.spot_replace_silent', '1', true);
  END IF;

  INSERT INTO public.meetup_spot_cards (
    session_id, match_id, sender_id, kind, storage_path, outfit, note, expires_at
  ) VALUES (
    NULL, p_match_id, v_uid, p_kind, p_storage_path,
    COALESCE(p_outfit, '{}'::jsonb), v_note,
    now() + make_interval(mins => v_spot_minutes)
  )
  RETURNING * INTO v_card;

  IF v_replacing THEN
    PERFORM set_config('meetup.spot_replace_silent', '0', true);
  END IF;

  RETURN to_jsonb(v_card);
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_spot_share_for_match(UUID, TEXT, TEXT, JSONB, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_spot_share_for_match(UUID, TEXT, TEXT, JSONB, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Alert composer: skip everything for a silent replacement.
--    Body is the 20262191000000 version (actor name, masked) unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_meetup_spot()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_locale TEXT;
  v_name TEXT;
  v_display TEXT;
  v_someone TEXT;
  v_title TEXT;
  v_body TEXT;
  v_data JSONB;
BEGIN
  IF NEW.sender_id IS NULL OR NEW.match_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;
  END IF;
  -- The sender replaced a live card during the same meet-up; the partner
  -- already has this card on screen.
  IF COALESCE(current_setting('meetup.spot_replace_silent', true), '0') = '1' THEN
    RETURN NEW;
  END IF;

  -- Locale belongs to the receiver; the name belongs to the actor.
  SELECT lower(btrim(COALESCE(u.preferred_language, 'en')))
    INTO v_locale
  FROM public.users u
  WHERE u.id IN (
    SELECT CASE
      WHEN m.user1_id = NEW.sender_id THEN m.user2_id
      ELSE m.user1_id
    END
    FROM public.matches m
    WHERE m.id = NEW.match_id
  );

  SELECT u.name INTO v_name
  FROM public.users u
  WHERE u.id = NEW.sender_id;

  v_locale := COALESCE(v_locale, 'en');
  IF v_locale LIKE 'he%' THEN v_locale := 'he';
  ELSIF v_locale LIKE 'es%' THEN v_locale := 'es';
  ELSE v_locale := 'en';
  END IF;

  v_someone := CASE
    WHEN v_locale = 'he' THEN 'מישהו'
    WHEN v_locale = 'es' THEN 'Alguien'
    ELSE 'Someone'
  END;
  -- mask_full_name returns NULL for a name that cannot be shown as
  -- "First L." (single-word); 'Unknown User' covers the older definition.
  v_display := COALESCE(
    NULLIF(public.mask_full_name(v_name), 'Unknown User'),
    v_someone
  );

  v_title := replace(
    public._match_extended_text(v_locale, 'meetupSpotPushTitle', '📸 {name}'),
    '{name}', v_display);
  v_body := replace(
    public._match_extended_text(v_locale, 'meetupSpotPushBody',
      '{name} sent a Spot me card'),
    '{name}', v_display);

  -- No photo path, outfit, note or location in the payload.
  v_data := jsonb_build_object(
    'type', 'meetup_spot',
    'kind', 'meetup_spot',
    'matchId', NEW.match_id::text,
    'match_id', NEW.match_id::text,
    'senderId', NEW.sender_id::text,
    'sender_id', NEW.sender_id::text,
    'meetup_spot_id', NEW.id::text,
    'spot_kind', NEW.kind
  );

  PERFORM public._meetup_notify_partner(
    NEW.sender_id, NEW.match_id, 'meetup_spot', v_title, v_body, v_data
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'notify_meetup_spot failed: %', SQLERRM;
  RETURN NEW;
END;
$$;
