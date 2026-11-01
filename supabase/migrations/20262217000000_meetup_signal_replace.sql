-- A new signal replaces the previous one instead of making the sender wait out
-- the old signal's life.
--
-- 1. The wave branch of both signal RPCs refused a second send for 30 seconds
--    and left the first row in place until it expired. The wait existed only
--    because every INSERT fires trg_notify_meetup_signal, which enqueues one
--    push per recipient device, and the tray card is keyed per row, so a burst
--    of gestures would stack a card and a buzz for each one. Nothing else about
--    the design needs it: the client already treats the newest row as
--    authoritative (MeetupState._latestSignal), so on screen the second signal
--    always won.
--
--    The beacon branch already implements the semantics the sender wants, so
--    wave now mirrors it exactly: keep a short guard against a double tap, then
--    delete the sender's own live rows of that type before the insert. The
--    delete is scoped to session/match + sender_id + type, so it can only ever
--    remove the sender's own live signals; the other person's rows and every
--    other tool are untouched.
--
--    30s -> 10s. Long enough that a deliberate double tap cannot buzz the
--    partner repeatedly, short enough that changing your mind feels immediate.
--    There is deliberately no separate suppression window on the push: a send
--    that the server rejects changes nothing anywhere, and a send the server
--    accepts must reach the partner's card, because the card is the only place
--    the change of mind would otherwise appear.
--
-- 2. Bug found on the way: the client calls meetup_signal_for_match(p_match_id),
--    while migration 20262163000000 (alert TTL alignment) redefined the older
--    meetup_signal(p_session_id) variant that no current build calls. The live
--    path therefore still hardcodes 60s/120s and ignores the admin keys
--    meetup.wave_expiry_seconds / meetup.beacon_expiry_seconds, which the
--    client's countdown reads. Both functions now resolve the TTLs from
--    app_config with the same defaults, so retuning those keys changes the
--    stored expiry as intended instead of only the bar.
--
-- The partner's tray entry is kept in sync by a stable collapse tag in
-- supabase/functions/cron-jobs/index.ts (meetup_signal / meetup_beacon keyed on
-- match + sender rather than on the row id). Deploy that function with this
-- migration, otherwise a replaced signal still adds a second card.
--
-- Idempotent; signatures are byte-identical to the originals, so CREATE OR
-- REPLACE replaces (no new overloads).

-- ---------------------------------------------------------------------------
-- 1) meetup_signal_for_match: the RPC the app calls.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.meetup_signal_for_match(
  p_match_id UUID,
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
  IF p_match_id IS NULL OR NOT public.meetup_match_participant(p_match_id) THEN
    RAISE EXCEPTION 'meetup_not_participant';
  END IF;

  IF p_payload IS NOT NULL AND char_length(p_payload::text) > 2000 THEN
    RAISE EXCEPTION 'meetup_invalid_signal';
  END IF;

  -- The alert-bar countdown on both devices reads these keys from app_config,
  -- so the stored expiry must be computed from them too. Non-numeric config
  -- values fall back to the defaults instead of erroring the RPC.
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
      WHERE match_id = p_match_id
        AND sender_id = v_uid
        AND type = 'wave'
        AND created_at > now() - interval '10 seconds'
    ) THEN
      RAISE EXCEPTION 'meetup_wave_rate_limited';
    END IF;
    DELETE FROM public.meetup_signals
    WHERE match_id = p_match_id
      AND sender_id = v_uid
      AND type = 'wave'
      AND expires_at > now();
    v_expires := now() + make_interval(secs => v_wave_seconds);
  ELSIF p_type = 'beacon' THEN
    IF EXISTS (
      SELECT 1 FROM public.meetup_signals
      WHERE match_id = p_match_id
        AND sender_id = v_uid
        AND type = 'beacon'
        AND created_at > now() - interval '20 seconds'
    ) THEN
      RAISE EXCEPTION 'meetup_beacon_rate_limited';
    END IF;
    DELETE FROM public.meetup_signals
    WHERE match_id = p_match_id
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
    NULL, p_match_id, v_uid, p_type,
    COALESCE(v_payload, '{}'::jsonb), v_expires
  )
  RETURNING * INTO v_signal;

  RETURN to_jsonb(v_signal);
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_signal_for_match(UUID, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_signal_for_match(UUID, TEXT, JSONB) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) meetup_signal: the session-scoped variant. No current build calls it, so
--    it is redefined only to keep the two paths from diverging again.
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
        AND created_at > now() - interval '10 seconds'
    ) THEN
      RAISE EXCEPTION 'meetup_wave_rate_limited';
    END IF;
    DELETE FROM public.meetup_signals
    WHERE session_id = v_session.id
      AND sender_id = v_uid
      AND type = 'wave'
      AND expires_at > now();
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
