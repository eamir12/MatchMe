-- Spot me: a card needs a photo or outfit values; a note alone is not a card.
--
-- The composer now keeps Share disabled until a selfie or one outfit value is
-- chosen, and both create paths reject an empty payload server-side so an old
-- or modified client cannot insert a card that carries only a note.
--
-- Existing note-only rows stay readable until they expire; no backfill.

-- ---------------------------------------------------------------------------
-- 1. Match-scoped share (current body: 20262193000000_meetup_spot_silent_replace)
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

  -- The photo is optional, but only when outfit values carry the card.
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

  IF p_storage_path = '' AND NOT EXISTS (
       SELECT 1
       FROM jsonb_each(COALESCE(p_outfit, '{}'::jsonb)) AS kv(key, value)
       WHERE kv.key IN (
               'shirt', 'shirt_color', 'pants', 'pants_color', 'shoes', 'shoes_color'
             )
         AND jsonb_typeof(kv.value) = 'string'
         AND btrim(kv.value #>> '{}') <> ''
     ) THEN
    RAISE EXCEPTION 'meetup_spot_content_required';
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
-- 2. Legacy session-scoped share (current body: 20262159000000_meetup_coordination)
--    Kept executable for installed builds; same content rule.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.meetup_spot_share(
  p_session_id UUID,
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
  v_session public.meetup_sessions%ROWTYPE;
  v_card public.meetup_spot_cards%ROWTYPE;
  v_count INTEGER;
  v_recent BOOLEAN;
  v_note TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'meetup_auth_required';
  END IF;

  SELECT * INTO v_session
  FROM public.meetup_sessions
  WHERE id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'meetup_not_found';
  END IF;
  IF NOT public.meetup_match_participant(v_session.match_id) THEN
    RAISE EXCEPTION 'meetup_not_participant';
  END IF;
  IF v_session.status NOT IN ('proposed', 'active')
     OR v_session.expires_at <= now() THEN
    RAISE EXCEPTION 'meetup_not_active';
  END IF;

  IF p_kind IS NULL OR p_kind NOT IN ('self', 'meeting_point') THEN
    RAISE EXCEPTION 'meetup_invalid_spot_kind';
  END IF;

  -- The photo is optional, but only when outfit values carry the card.
  p_storage_path := COALESCE(btrim(p_storage_path), '');
  IF p_storage_path <> ''
     AND p_storage_path NOT LIKE v_session.id::text || '/' || v_uid::text || '/%' THEN
    RAISE EXCEPTION 'meetup_invalid_spot_path';
  END IF;

  -- This RPC predates outfit shape validation, so guard the jsonb cast.
  IF p_storage_path = '' AND NOT EXISTS (
       SELECT 1
       FROM jsonb_each(
         CASE WHEN jsonb_typeof(COALESCE(p_outfit, '{}'::jsonb)) = 'object'
              THEN COALESCE(p_outfit, '{}'::jsonb)
              ELSE '{}'::jsonb
         END
       ) AS kv(key, value)
       WHERE kv.key IN (
               'shirt', 'shirt_color', 'pants', 'pants_color', 'shoes', 'shoes_color'
             )
         AND jsonb_typeof(kv.value) = 'string'
         AND btrim(kv.value #>> '{}') <> ''
     ) THEN
    RAISE EXCEPTION 'meetup_spot_content_required';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.meetup_spot_cards
  WHERE session_id = v_session.id AND sender_id = v_uid;
  IF v_count >= 5 THEN
    RAISE EXCEPTION 'meetup_spot_limit';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.meetup_spot_cards
    WHERE session_id = v_session.id
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

  UPDATE public.meetup_spot_cards
  SET deleted_at = now()
  WHERE session_id = v_session.id
    AND sender_id = v_uid
    AND deleted_at IS NULL;

  INSERT INTO public.meetup_spot_cards (
    session_id, match_id, sender_id, kind, storage_path, outfit, note, expires_at
  ) VALUES (
    v_session.id, v_session.match_id, v_uid, p_kind, p_storage_path,
    COALESCE(p_outfit, '{}'::jsonb), v_note,
    LEAST(v_session.expires_at, now() + interval '2 hours')
  )
  RETURNING * INTO v_card;

  RETURN to_jsonb(v_card);
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_spot_share(UUID, TEXT, TEXT, JSONB, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_spot_share(UUID, TEXT, TEXT, JSONB, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Copy for the composer notice and the server rejection message
-- ---------------------------------------------------------------------------
INSERT INTO public.translations (locale, key, value) VALUES
('en', 'meetupSpotMeContentRequired', 'Add a photo or outfit details to share.'),
('es', 'meetupSpotMeContentRequired', 'Agrega una foto o detalles de tu ropa para compartir.'),
('he', 'meetupSpotMeContentRequired', 'הוסיפו תמונה או פרטי לבוש כדי לשתף.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
