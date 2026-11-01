-- Meet-up alert TTL alignment + beacon push copy fix.
--
-- 1. The wave (60s) and beacon (120s) lifetimes were hardcoded server-side
--    while the client's alert-bar countdown reads meetup.wave_expiry_seconds
--    and meetup.beacon_expiry_seconds from app_config. An admin tuning those
--    keys would promise the bar more time than the row actually has. Both
--    functions now read the same keys (defaults unchanged). Same fix for
--    Spot cards, whose lifetime was hardcoded to 2 hours while the client
--    reads meetup.spot_card_expiry_minutes.
--
-- 2. The beacon push body said "broadcasting", which reads as a location
--    feature. The beacon shares no location: it is a bright shape derived
--    from the session ID, held up on the sender's screen for the receiver
--    to look for. Reworded to match the in-app copy ("Look for this shape
--    on their screen."). The en/es/he inbox rows are the values actually
--    used; the trigger's inline English fallback literal is shadowed by
--    them and left untouched on purpose.
--
-- Idempotent; safe to re-run. Signatures are byte-identical to the
-- originals, so CREATE OR REPLACE replaces (no new overloads).

-- ---------------------------------------------------------------------------
-- 1a. Wave + beacon expiry from app_config (defaults unchanged: 60s / 120s)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.meetup_signal(
  p_session_id UUID,
  p_type TEXT,
  p_payload JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_session public.meetup_sessions%ROWTYPE;
  v_signal public.meetup_signals%ROWTYPE;
  v_expires TIMESTAMPTZ;
  v_gesture TEXT;
  v_payload JSONB;
  v_wave_seconds INT;
  v_beacon_seconds INT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'meetup_auth_required';
  END IF;

  -- Keep the receiver's alert-bar countdown honest: it counts down the same
  -- keys, so the stored expiry must be computed from them too. Non-numeric
  -- config values fall back to the defaults instead of erroring the RPC.
  SELECT GREATEST(COALESCE((
    SELECT CASE WHEN jsonb_typeof(config_value) = 'number'
                THEN (config_value #>> '{}')::int END
    FROM public.app_config
    WHERE config_key = 'meetup.wave_expiry_seconds'
  ), 60), 1)
  INTO v_wave_seconds;

  SELECT GREATEST(COALESCE((
    SELECT CASE WHEN jsonb_typeof(config_value) = 'number'
                THEN (config_value #>> '{}')::int END
    FROM public.app_config
    WHERE config_key = 'meetup.beacon_expiry_seconds'
  ), 120), 1)
  INTO v_beacon_seconds;

  SELECT * INTO v_session
  FROM public.meetup_sessions
  WHERE id = p_session_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'meetup_not_found';
  END IF;
  IF NOT public.meetup_match_participant(v_session.match_id) THEN
    RAISE EXCEPTION 'meetup_not_participant';
  END IF;
  -- Coordination tools work as soon as a meet-up exists, before the other
  -- side has agreed on a place.
  IF v_session.status NOT IN ('proposed', 'active')
     OR v_session.expires_at <= now() THEN
    RAISE EXCEPTION 'meetup_not_active';
  END IF;

  IF p_payload IS NOT NULL AND char_length(p_payload::text) > 2000 THEN
    RAISE EXCEPTION 'meetup_invalid_signal';
  END IF;

  IF p_type = 'wave' THEN
    v_gesture := lower(btrim(COALESCE(p_payload->>'gesture', '')));
    IF v_gesture = '' THEN
      v_gesture := 'wave';
    END IF;
    IF v_gesture NOT IN ('wave', 'hands_up', 'jumping', 'arms_wide') THEN
      RAISE EXCEPTION 'meetup_invalid_signal';
    END IF;
    v_payload := jsonb_build_object('gesture', v_gesture);

    IF EXISTS (
      SELECT 1 FROM public.meetup_signals
      WHERE session_id = v_session.id
        AND sender_id = v_uid
        AND type = 'wave'
        AND created_at > now() - interval '30 seconds'
    ) THEN
      RAISE EXCEPTION 'meetup_wave_rate_limited';
    END IF;
    v_expires := now() + make_interval(secs => v_wave_seconds);
  ELSIF p_type = 'beacon' THEN
    IF EXISTS (
      SELECT 1 FROM public.meetup_signals
      WHERE session_id = v_session.id
        AND sender_id = v_uid
        AND type = 'beacon'
        AND created_at > now() - interval '20 seconds'
    ) THEN
      RAISE EXCEPTION 'meetup_beacon_rate_limited';
    END IF;
    DELETE FROM public.meetup_signals
    WHERE session_id = v_session.id
      AND sender_id = v_uid
      AND type = 'beacon'
      AND expires_at > now();
    v_payload := '{}'::jsonb;
    v_expires := now() + make_interval(secs => v_beacon_seconds);
  ELSE
    RAISE EXCEPTION 'meetup_invalid_signal';
  END IF;

  INSERT INTO public.meetup_signals (
    session_id, match_id, sender_id, type, payload, expires_at
  ) VALUES (
    v_session.id, v_session.match_id, v_uid, p_type,
    COALESCE(v_payload, '{}'::jsonb), v_expires
  )
  RETURNING * INTO v_signal;

  RETURN to_jsonb(v_signal);
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_signal(UUID, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_signal(UUID, TEXT, JSONB) TO authenticated;

-- ---------------------------------------------------------------------------
-- 1b. Spot card expiry from app_config (default unchanged: 120 minutes)
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

  SELECT EXISTS (
    SELECT 1 FROM public.meetup_spot_cards
    WHERE match_id = p_match_id
      AND sender_id = v_uid
      AND created_at > now() - interval '60 seconds'
  ) INTO v_recent;
  IF v_recent THEN
    RAISE EXCEPTION 'meetup_spot_rate_limited';
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

  -- One live card per sender and match, as before.
  UPDATE public.meetup_spot_cards
  SET deleted_at = now()
  WHERE match_id = p_match_id
    AND sender_id = v_uid
    AND deleted_at IS NULL;

  INSERT INTO public.meetup_spot_cards (
    session_id, match_id, sender_id, kind, storage_path, outfit, note, expires_at
  ) VALUES (
    NULL, p_match_id, v_uid, p_kind, p_storage_path,
    COALESCE(p_outfit, '{}'::jsonb), v_note,
    now() + make_interval(mins => v_spot_minutes)
  )
  RETURNING * INTO v_card;

  RETURN to_jsonb(v_card);
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_spot_share_for_match(UUID, TEXT, TEXT, JSONB, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_spot_share_for_match(UUID, TEXT, TEXT, JSONB, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Beacon push copy: "broadcasting" implied location. The beacon shares no
--    location — it is a shape held up on the sender's screen. Align the push
--    body with the in-app copy ("Look for this shape on their screen.").
-- ---------------------------------------------------------------------------

INSERT INTO public.translations (locale, key, value) VALUES
('en', 'meetupBeaconPushBody', '{name} is showing a beacon. Look for the shape on their screen'),
('es', 'meetupBeaconPushBody', '{name} está mostrando una baliza. Busca la forma en su pantalla'),
('he', 'meetupBeaconPushBody', '{name} מציג/ה איתות. חפשו את הצורה במסך שלהם')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
