-- Meet-up coordination extensions.
--
-- Adds the approved six-change batch on top of 20262156000000_meetup_sessions:
--   * gestures beyond a plain wave (payload.gesture whitelist),
--   * wave/beacon/Spot me usable on proposed sessions (before a place is
--     agreed), on both sides,
--   * name-only custom meeting places (no coordinates stored),
--   * a consent-based meeting-point change while a meet-up is active,
--   * outfit color tokens (localized on the client),
--   * American-English copy and translations for every new key (en/es/he).
--
-- Privacy invariants are unchanged: no user location is written. Custom
-- places store only a name; pending changes reuse the existing landmark rows
-- (round 3) and are deleted on decline/withdraw/end.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Session pending-change columns
-- ---------------------------------------------------------------------------

ALTER TABLE public.meetup_sessions
  ADD COLUMN IF NOT EXISTS pending_landmark_id UUID,
  ADD COLUMN IF NOT EXISTS pending_change_by UUID,
  ADD COLUMN IF NOT EXISTS pending_change_at TIMESTAMPTZ;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'meetup_sessions_pending_landmark_fk'
  ) THEN
    ALTER TABLE public.meetup_sessions
      ADD CONSTRAINT meetup_sessions_pending_landmark_fk
      FOREIGN KEY (pending_landmark_id)
      REFERENCES public.meetup_landmarks(id)
      ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'meetup_sessions_pending_change_by_fk'
  ) THEN
    ALTER TABLE public.meetup_sessions
      ADD CONSTRAINT meetup_sessions_pending_change_by_fk
      FOREIGN KEY (pending_change_by)
      REFERENCES public.users(id)
      ON DELETE SET NULL;
  END IF;
END;
$$;

-- Round 3 holds active meet-up change suggestions. Initial proposals and
-- counters keep using rounds 1 and 2.
ALTER TABLE public.meetup_landmarks
  DROP CONSTRAINT IF EXISTS meetup_landmarks_round_check;
ALTER TABLE public.meetup_landmarks
  ADD CONSTRAINT meetup_landmarks_round_check
  CHECK (round IN (1, 2, 3));

CREATE INDEX IF NOT EXISTS idx_meetup_landmarks_pending
  ON public.meetup_landmarks(session_id, round)
  WHERE round = 3;

-- ---------------------------------------------------------------------------
-- 2. Landmark insert helper: custom places have no coordinates
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.meetup_insert_landmarks(
  p_session_id UUID,
  p_match_id UUID,
  p_proposer_id UUID,
  p_round SMALLINT,
  p_landmarks JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item JSONB;
  v_label TEXT;
  v_category TEXT;
  v_lat DOUBLE PRECISION;
  v_lng DOUBLE PRECISION;
  v_distance INTEGER;
BEGIN
  IF p_landmarks IS NULL OR jsonb_typeof(p_landmarks) <> 'array' THEN
    RAISE EXCEPTION 'meetup_invalid_landmarks';
  END IF;
  IF p_round IS NULL OR p_round NOT IN (1, 2, 3) THEN
    RAISE EXCEPTION 'meetup_invalid_landmarks';
  END IF;
  IF jsonb_array_length(p_landmarks) < 1 OR jsonb_array_length(p_landmarks) > 3 THEN
    RAISE EXCEPTION 'meetup_invalid_landmarks';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_landmarks)
  LOOP
    v_label := btrim(COALESCE(v_item->>'label', ''));
    v_category := lower(btrim(COALESCE(v_item->>'category', 'landmark')));
    IF v_label = '' OR char_length(v_label) > 160 THEN
      RAISE EXCEPTION 'meetup_invalid_landmarks';
    END IF;
    IF v_category = '' OR char_length(v_category) > 40 THEN
      v_category := 'landmark';
    END IF;

    BEGIN
      v_lat := NULLIF(btrim(COALESCE(v_item->>'lat', '')), '')::DOUBLE PRECISION;
      v_lng := NULLIF(btrim(COALESCE(v_item->>'lng', '')), '')::DOUBLE PRECISION;
    EXCEPTION WHEN OTHERS THEN
      v_lat := NULL;
      v_lng := NULL;
    END;

    BEGIN
      v_distance := NULLIF(btrim(COALESCE(v_item->>'distance_m', '')), '')::INTEGER;
    EXCEPTION WHEN OTHERS THEN
      v_distance := NULL;
    END;
    IF v_distance IS NOT NULL AND (v_distance < 0 OR v_distance > 100000) THEN
      v_distance := NULL;
    END IF;

    IF v_category = 'custom' THEN
      -- A custom place is a name only. Never persist coordinates or a
      -- distance for it, even if a caller tries to include them.
      v_lat := NULL;
      v_lng := NULL;
      v_distance := NULL;
    ELSE
      IF v_lat IS NULL OR v_lng IS NULL
         OR v_lat < -90 OR v_lat > 90
         OR v_lng < -180 OR v_lng > 180 THEN
        RAISE EXCEPTION 'meetup_invalid_landmarks';
      END IF;
    END IF;

    INSERT INTO public.meetup_landmarks (
      session_id, match_id, proposer_id, round, label, category,
      latitude, longitude, distance_m
    ) VALUES (
      p_session_id, p_match_id, p_proposer_id, p_round, v_label, v_category,
      v_lat, v_lng, v_distance
    );
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_insert_landmarks(UUID, UUID, UUID, SMALLINT, JSONB) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Signals: any open session, whitelisted gestures
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
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'meetup_auth_required';
  END IF;

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
    v_expires := now() + interval '60 seconds';
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
    v_expires := now() + interval '120 seconds';
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
-- 4. Spot me: any open session (selfie-only enforced by the client)
-- ---------------------------------------------------------------------------

-- The base migration only let photos upload while the session was active.
-- Spot me is now available before a place is agreed, so proposed sessions
-- must accept the upload too. Reading already allows every participant.
CREATE OR REPLACE FUNCTION public.meetup_storage_can_write(
  p_session_id TEXT,
  p_owner_id TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.meetup_sessions s
    JOIN public.matches m ON m.id = s.match_id
    WHERE s.id::text = p_session_id
      AND s.status IN ('proposed', 'active')
      AND s.expires_at > now()
      AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
      AND p_owner_id = auth.uid()::text
  );
$$;

REVOKE ALL ON FUNCTION public.meetup_storage_can_write(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_storage_can_write(TEXT, TEXT) TO authenticated;

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
  -- A card may contain only outfit details/note and no photo at all.
  p_storage_path := COALESCE(btrim(p_storage_path), '');
  IF p_storage_path <> ''
     AND p_storage_path NOT LIKE v_session.id::text || '/' || v_uid::text || '/%' THEN
    RAISE EXCEPTION 'meetup_invalid_spot_path';
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
-- 5. Active meeting-point change (consent-based)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.meetup_request_place_change(
  p_session_id UUID,
  p_landmarks JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_session public.meetup_sessions%ROWTYPE;
  v_landmark_id UUID;
  v_pending public.meetup_landmarks%ROWTYPE;
  v_item JSONB;
  v_label TEXT;
  v_category TEXT;
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
  IF v_session.status <> 'active' OR v_session.expires_at <= now() THEN
    RAISE EXCEPTION 'meetup_not_active';
  END IF;
  IF v_session.origin <> 'proximity' THEN
    -- Event meet-ups use a venue zone, not a landmark; changing the zone
    -- while the meet-up is active is out of scope.
    RAISE EXCEPTION 'meetup_place_change_unavailable';
  END IF;
  IF v_session.pending_landmark_id IS NOT NULL THEN
    RAISE EXCEPTION 'meetup_place_change_pending';
  END IF;
  IF p_landmarks IS NULL OR jsonb_typeof(p_landmarks) <> 'array'
     OR jsonb_array_length(p_landmarks) <> 1 THEN
    RAISE EXCEPTION 'meetup_invalid_landmarks';
  END IF;

  -- Only one new place per request. The other side accepts or declines it.
  v_item := p_landmarks->0;
  v_label := btrim(COALESCE(v_item->>'label', ''));
  v_category := lower(btrim(COALESCE(v_item->>'category', 'landmark')));
  IF v_label = '' OR char_length(v_label) > 160 THEN
    RAISE EXCEPTION 'meetup_invalid_landmarks';
  END IF;
  IF v_category = '' OR char_length(v_category) > 40 THEN
    v_category := 'landmark';
  END IF;

  -- Drop abandoned round-3 suggestions from earlier requests. Never touch
  -- the accepted place or the currently pending one.
  DELETE FROM public.meetup_landmarks l
  WHERE l.session_id = v_session.id
    AND l.round = 3
    AND l.id IS DISTINCT FROM v_session.chosen_landmark_id
    AND l.id IS DISTINCT FROM v_session.pending_landmark_id;

  PERFORM public.meetup_insert_landmarks(
    v_session.id, v_session.match_id, v_uid, 3::SMALLINT, p_landmarks
  );

  SELECT * INTO v_pending
  FROM public.meetup_landmarks
  WHERE session_id = v_session.id
    AND round = 3
    AND proposer_id = v_uid
  ORDER BY created_at DESC, id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'meetup_invalid_landmarks';
  END IF;
  v_landmark_id := v_pending.id;

  UPDATE public.meetup_sessions
  SET pending_landmark_id = v_landmark_id,
      pending_change_by = v_uid,
      pending_change_at = now()
  WHERE id = v_session.id
  RETURNING * INTO v_session;

  RETURN to_jsonb(v_session);
END;
$$;

CREATE OR REPLACE FUNCTION public.meetup_resolve_place_change(
  p_session_id UUID,
  p_accept BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_session public.meetup_sessions%ROWTYPE;
  v_pending_id UUID;
  v_exists BOOLEAN;
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
  IF v_session.status <> 'active' OR v_session.expires_at <= now() THEN
    RAISE EXCEPTION 'meetup_not_active';
  END IF;
  IF v_session.pending_landmark_id IS NULL THEN
    RAISE EXCEPTION 'meetup_no_place_change';
  END IF;
  IF v_session.pending_change_by = v_uid THEN
    RAISE EXCEPTION 'meetup_waiting_for_other';
  END IF;

  v_pending_id := v_session.pending_landmark_id;

  IF p_accept IS TRUE THEN
    SELECT EXISTS (
      SELECT 1 FROM public.meetup_landmarks
      WHERE id = v_pending_id AND session_id = v_session.id
    ) INTO v_exists;
    IF NOT v_exists THEN
      RAISE EXCEPTION 'meetup_no_place_change';
    END IF;

    UPDATE public.meetup_sessions
    SET chosen_landmark_id = v_pending_id,
        pending_landmark_id = NULL,
        pending_change_by = NULL,
        pending_change_at = NULL
    WHERE id = v_session.id
    RETURNING * INTO v_session;
  ELSE
    UPDATE public.meetup_sessions
    SET pending_landmark_id = NULL,
        pending_change_by = NULL,
        pending_change_at = NULL
    WHERE id = v_session.id
    RETURNING * INTO v_session;

    DELETE FROM public.meetup_landmarks
    WHERE id = v_pending_id
      AND id IS DISTINCT FROM v_session.chosen_landmark_id;
  END IF;

  RETURN to_jsonb(v_session);
END;
$$;

CREATE OR REPLACE FUNCTION public.meetup_withdraw_place_change(
  p_session_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_session public.meetup_sessions%ROWTYPE;
  v_pending_id UUID;
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
  IF v_session.status <> 'active' OR v_session.expires_at <= now() THEN
    RAISE EXCEPTION 'meetup_not_active';
  END IF;
  IF v_session.pending_landmark_id IS NULL THEN
    RAISE EXCEPTION 'meetup_no_place_change';
  END IF;
  IF v_session.pending_change_by IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'meetup_not_requester';
  END IF;

  v_pending_id := v_session.pending_landmark_id;

  UPDATE public.meetup_sessions
  SET pending_landmark_id = NULL,
      pending_change_by = NULL,
      pending_change_at = NULL
  WHERE id = v_session.id
  RETURNING * INTO v_session;

  DELETE FROM public.meetup_landmarks
  WHERE id = v_pending_id
    AND id IS DISTINCT FROM v_session.chosen_landmark_id;

  RETURN to_jsonb(v_session);
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_request_place_change(UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_resolve_place_change(UUID, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_withdraw_place_change(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_request_place_change(UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_resolve_place_change(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_withdraw_place_change(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. End cleanup for pending changes
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.meetup_end(
  p_session_id UUID,
  p_reason TEXT DEFAULT 'found'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_session public.meetup_sessions%ROWTYPE;
  v_reason TEXT;
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

  IF v_session.status = 'ended' THEN
    RETURN to_jsonb(v_session);
  END IF;

  v_reason := CASE
    WHEN p_reason IN ('found', 'cancelled') THEN p_reason
    ELSE 'cancelled'
  END;

  UPDATE public.meetup_sessions
  SET status = 'ended',
      ended_at = now(),
      ended_by = v_uid,
      end_reason = v_reason,
      pending_landmark_id = NULL,
      pending_change_by = NULL,
      pending_change_at = NULL
  WHERE id = v_session.id
  RETURNING * INTO v_session;

  DELETE FROM public.meetup_signals WHERE session_id = v_session.id;
  UPDATE public.meetup_spot_cards
  SET deleted_at = now()
  WHERE session_id = v_session.id AND deleted_at IS NULL;

  -- Keep the accepted place for the ended-session summary; drop suggestions
  -- that were never accepted.
  DELETE FROM public.meetup_landmarks
  WHERE session_id = v_session.id
    AND round = 3
    AND id IS DISTINCT FROM v_session.chosen_landmark_id;

  RETURN to_jsonb(v_session);
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_end(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_end(UUID, TEXT) TO authenticated;

-- Expiry cleanup: clear any pending change and drop never-accepted round-3
-- suggestions so a stale pending place cannot surface after the fact.
CREATE OR REPLACE FUNCTION public.cleanup_expired_meetups()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.meetup_sessions
  SET status = 'ended',
      ended_at = now(),
      end_reason = 'expired',
      pending_landmark_id = NULL,
      pending_change_by = NULL,
      pending_change_at = NULL
  WHERE status IN ('proposed', 'active')
    AND expires_at < now();

  DELETE FROM public.meetup_landmarks l
  USING public.meetup_sessions s
  WHERE l.session_id = s.id
    AND l.round = 3
    AND s.status = 'ended'
    AND l.id IS DISTINCT FROM s.chosen_landmark_id;

  DELETE FROM public.meetup_signals WHERE expires_at < now();

  UPDATE public.meetup_spot_cards
  SET deleted_at = now()
  WHERE deleted_at IS NULL
    AND expires_at < now();

  -- Keep ended sessions for a day so both clients can purge their spot
  -- objects, then drop the rows (cascade removes landmarks/signals/cards).
  DELETE FROM public.meetup_sessions
  WHERE status = 'ended'
    AND ended_at < now() - interval '24 hours';
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_expired_meetups() FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 7. Copy fixes and new translations (en/es/he)
-- ---------------------------------------------------------------------------

INSERT INTO public.translations (locale, key, value) VALUES
-- American English value fixes (identifiers and stored status tokens stay).
('en','meetupOutfitColor','Color'),
('en','meetupOutfitTrousers','Dress pants'),
('en','meetupEndedCancelled','Meet-up canceled.'),
('en','authCaptchaCancelled','Security check was canceled.'),
('en','authOAuthCancelled','Sign-in canceled'),
('en','authPasskeyCancelled','Passkey authentication was canceled'),
('en','billingCancelled','Canceled'),
('en','billingCancelledOn','Canceled on'),
('en','calendarSyncGoogleSignInCancelled','Google sign-in was canceled. Please try again.'),
('en','adminBroadcastsStatusCancelled','Canceled'),

-- Tool availability / gestures
('en','meetupToolsTitle','Coordinate now'),
('en','meetupToolsHint','These work before and after you choose a meeting point.'),
('en','meetupSignal','Signal'),
('en','meetupSignalHint','Wave, raise both hands, jump, or open your arms so they can spot you.'),
('en','meetupGestureSheetTitle','Choose a gesture'),
('en','meetupGestureSheetBody','They will see the gesture you choose.'),
('en','meetupGestureWave','Wave'),
('en','meetupGestureHandsUp','Both hands up'),
('en','meetupGestureJumping','Jumping'),
('en','meetupGestureArmsWide','Arms wide'),
('en','meetupGestureSent','{gesture} sent'),
('en','meetupGestureIncomingTitle','{name} is signaling: {gesture}'),
('en','meetupGestureIncomingBody','Look for this gesture so you can spot each other.'),
('en','meetupSignalBack','Signal back'),
('en','meetupBannerGesture','{name} is signaling: {gesture}'),
('en','meetupBeaconTapHint','You can signal, show a beacon, or share a Spot me card before and after you choose a meeting point.'),
('en','meetupWaveHint','Send a gesture so they can spot you'),

-- Custom meeting places
('en','meetupCustomPlace','Enter a place'),
('en','meetupCustomPlaceTitle','Name a meeting place'),
('en','meetupCustomPlaceBody','Use a place the suggestions missed. Only the name is shared; no coordinates are saved.'),
('en','meetupCustomPlaceLabel','Place name'),
('en','meetupCustomPlaceHint','e.g. Outside the corner bakery'),
('en','meetupCustomPlaceAdd','Use this place'),
('en','meetupCustomPlaceInvalid','Enter a place name.'),
('en','meetupCategoryCustom','Custom place'),

-- Active meeting-point change
('en','meetupChangePlace','Change meeting point'),
('en','meetupChangePlaceTitle','Suggest a new meeting point'),
('en','meetupChangePlaceBody','The current meeting point stays until they accept.'),
('en','meetupChangePlaceSent','Change request sent'),
('en','meetupChangePlacePropose','Suggest this place'),
('en','meetupChangePlaceWaiting','Waiting for {name} to respond to your new meeting point'),
('en','meetupChangePlaceIncomingTitle','{name} suggested a new meeting point'),
('en','meetupChangePlaceIncomingBody','The current meeting point stays until you decide.'),
('en','meetupChangePlaceAccept','Use new place'),
('en','meetupChangePlaceKeep','Keep current place'),
('en','meetupChangePlaceWithdraw','Withdraw request'),
('en','meetupChangePlaceDeclined','Current meeting point kept'),
('en','meetupChangePlaceAccepted','Meeting point updated'),
('en','meetupChangePlaceWithdrawn','Change request withdrawn'),
('en','meetupChangePlacePendingLabel','Proposed new place'),
('en','meetupChangePlaceNewPlace','New place: {place}'),
('en','meetupChangePlaceUnavailable','The meeting point cannot be changed for this meet-up.'),
('en','meetupChangePlacePendingError','A change request is already pending.'),
('en','meetupChangePlaceNoPending','No change request is pending.'),

-- Spot me selfie capture
('en','meetupSpotMeSelfie','Take a selfie'),
('en','meetupSpotMeRetake','Retake selfie'),
('en','meetupSpotMeSelfieHint','Use your front camera. Only the photo is shared.'),
('en','meetupSpotMeCameraUnavailable','Camera is not available here. Add outfit details or a note instead.'),
('en','meetupSpotMeCameraDenied','Camera access is needed for a selfie. You can add outfit details or a note instead.'),
('en','meetupSpotMeCaptureFailed','Could not take the selfie. Try again, or add details instead.'),
('en','meetupSpotMeHint','Take a selfie or share what you are wearing'),

-- Outfit colors
('en','meetupOutfitColorUnspecified','Not specified'),
('en','meetupColorBlack','Black'),
('en','meetupColorWhite','White'),
('en','meetupColorGray','Gray'),
('en','meetupColorBeige','Beige'),
('en','meetupColorBrown','Brown'),
('en','meetupColorNavy','Navy'),
('en','meetupColorBlue','Blue'),
('en','meetupColorLightBlue','Light blue'),
('en','meetupColorGreen','Green'),
('en','meetupColorOlive','Olive'),
('en','meetupColorRed','Red'),
('en','meetupColorBurgundy','Burgundy'),
('en','meetupColorPink','Pink'),
('en','meetupColorYellow','Yellow'),
('en','meetupColorOrange','Orange'),
('en','meetupColorPurple','Purple'),
('en','meetupColorGold','Gold'),
('en','meetupColorSilver','Silver'),
('en','meetupColorMulticolor','Multicolor'),

-- Map attribution
('en','meetupOsmAttribution','© OpenStreetMap contributors'),

-- Spanish
('es','meetupToolsTitle','Coordina ahora'),
('es','meetupToolsHint','Funcionan antes y después de elegir un punto de encuentro.'),
('es','meetupSignal','Señal'),
('es','meetupSignalHint','Saluda, levanta ambas manos, salta o abre los brazos para que te vean.'),
('es','meetupGestureSheetTitle','Elige un gesto'),
('es','meetupGestureSheetBody','Verán el gesto que elijas.'),
('es','meetupGestureWave','Saludar'),
('es','meetupGestureHandsUp','Ambas manos arriba'),
('es','meetupGestureJumping','Saltando'),
('es','meetupGestureArmsWide','Brazos abiertos'),
('es','meetupGestureSent','{gesture} enviado'),
('es','meetupGestureIncomingTitle','{name} está haciendo una señal: {gesture}'),
('es','meetupGestureIncomingBody','Busca este gesto para que puedan verse.'),
('es','meetupSignalBack','Responder con una señal'),
('es','meetupBannerGesture','{name} está haciendo una señal: {gesture}'),
('es','meetupBeaconTapHint','Puedes enviar una señal, mostrar una baliza o compartir una tarjeta Spot me antes y después de elegir un punto de encuentro.'),
('es','meetupWaveHint','Envía un gesto para que te vean'),
('es','meetupCustomPlace','Escribir un lugar'),
('es','meetupCustomPlaceTitle','Nombra un punto de encuentro'),
('es','meetupCustomPlaceBody','Usa un lugar que no aparezca en las sugerencias. Solo se comparte el nombre; no se guardan coordenadas.'),
('es','meetupCustomPlaceLabel','Nombre del lugar'),
('es','meetupCustomPlaceHint','p. ej. Frente a la panadería de la esquina'),
('es','meetupCustomPlaceAdd','Usar este lugar'),
('es','meetupCustomPlaceInvalid','Escribe el nombre de un lugar.'),
('es','meetupCategoryCustom','Lugar personalizado'),
('es','meetupChangePlace','Cambiar punto de encuentro'),
('es','meetupChangePlaceTitle','Sugerir un nuevo punto de encuentro'),
('es','meetupChangePlaceBody','El punto de encuentro actual se mantiene hasta que acepten.'),
('es','meetupChangePlaceSent','Solicitud de cambio enviada'),
('es','meetupChangePlacePropose','Proponer este lugar'),
('es','meetupChangePlaceWaiting','Esperando a que {name} responda a tu nuevo punto de encuentro'),
('es','meetupChangePlaceIncomingTitle','{name} sugirió un nuevo punto de encuentro'),
('es','meetupChangePlaceIncomingBody','El punto de encuentro actual se mantiene hasta que decidas.'),
('es','meetupChangePlaceAccept','Usar el nuevo lugar'),
('es','meetupChangePlaceKeep','Mantener el lugar actual'),
('es','meetupChangePlaceWithdraw','Retirar solicitud'),
('es','meetupChangePlaceDeclined','Se mantiene el punto de encuentro actual'),
('es','meetupChangePlaceAccepted','Punto de encuentro actualizado'),
('es','meetupChangePlaceWithdrawn','Solicitud de cambio retirada'),
('es','meetupChangePlacePendingLabel','Nuevo lugar propuesto'),
('es','meetupChangePlaceNewPlace','Nuevo lugar: {place}'),
('es','meetupChangePlaceUnavailable','El punto de encuentro no se puede cambiar en este encuentro.'),
('es','meetupChangePlacePendingError','Ya hay una solicitud de cambio pendiente.'),
('es','meetupChangePlaceNoPending','No hay ninguna solicitud de cambio pendiente.'),
('es','meetupSpotMeSelfie','Tomar una selfi'),
('es','meetupSpotMeRetake','Volver a tomar la selfi'),
('es','meetupSpotMeSelfieHint','Usa la cámara frontal. Solo se comparte la foto.'),
('es','meetupSpotMeCameraUnavailable','La cámara no está disponible aquí. Añade detalles de tu ropa o una nota.'),
('es','meetupSpotMeCameraDenied','Se necesita acceso a la cámara para una selfi. Puedes añadir detalles de tu ropa o una nota.'),
('es','meetupSpotMeCaptureFailed','No se pudo tomar la selfi. Inténtalo de nuevo o añade detalles.'),
('es','meetupSpotMeHint','Toma una selfi o comparte lo que llevas puesto'),
('es','meetupOutfitColorUnspecified','Sin especificar'),
('es','meetupColorBlack','Negro'),
('es','meetupColorWhite','Blanco'),
('es','meetupColorGray','Gris'),
('es','meetupColorBeige','Beige'),
('es','meetupColorBrown','Marrón'),
('es','meetupColorNavy','Azul marino'),
('es','meetupColorBlue','Azul'),
('es','meetupColorLightBlue','Azul claro'),
('es','meetupColorGreen','Verde'),
('es','meetupColorOlive','Oliva'),
('es','meetupColorRed','Rojo'),
('es','meetupColorBurgundy','Borgoña'),
('es','meetupColorPink','Rosa'),
('es','meetupColorYellow','Amarillo'),
('es','meetupColorOrange','Naranja'),
('es','meetupColorPurple','Morado'),
('es','meetupColorGold','Dorado'),
('es','meetupColorSilver','Plateado'),
('es','meetupColorMulticolor','Multicolor'),
('es','meetupOsmAttribution','© OpenStreetMap contributors'),

-- Hebrew
('he','meetupToolsTitle','לתאם עכשיו'),
('he','meetupToolsHint','הם עובדים לפני ואחרי בחירת נקודת מפגש.'),
('he','meetupSignal','אות'),
('he','meetupSignalHint','נופפו, הרימו שתי ידיים, קפצו או פרשו ידיים כדי שיזהו אתכם.'),
('he','meetupGestureSheetTitle','בחרו תנועה'),
('he','meetupGestureSheetBody','הם יראו את התנועה שתבחרו.'),
('he','meetupGestureWave','נפנוף'),
('he','meetupGestureHandsUp','שתי הידיים למעלה'),
('he','meetupGestureJumping','קפיצה'),
('he','meetupGestureArmsWide','ידיים פרושות'),
('he','meetupGestureSent','{gesture} נשלח'),
('he','meetupGestureIncomingTitle','{name} מסמן/ת: {gesture}'),
('he','meetupGestureIncomingBody','חפשו את התנועה הזו כדי לזהות אחד את השני.'),
('he','meetupSignalBack','לסמן חזרה'),
('he','meetupBannerGesture','{name} מסמן/ת: {gesture}'),
('he','meetupBeaconTapHint','אפשר לסמן, להציג משואה או לשתף כרטיס זיהוי לפני ואחרי בחירת נקודת מפגש.'),
('he','meetupWaveHint','שלחו תנועה כדי שיזהו אתכם'),
('he','meetupCustomPlace','הזנת מקום'),
('he','meetupCustomPlaceTitle','תנו שם לנקודת מפגש'),
('he','meetupCustomPlaceBody','השתמשו במקום שלא הופיע בהצעות. רק השם משותף; קואורדינטות לא נשמרות.'),
('he','meetupCustomPlaceLabel','שם המקום'),
('he','meetupCustomPlaceHint','למשל: מחוץ למאפייה בפינה'),
('he','meetupCustomPlaceAdd','להשתמש במקום הזה'),
('he','meetupCustomPlaceInvalid','הזינו שם מקום.'),
('he','meetupCategoryCustom','מקום מותאם'),
('he','meetupChangePlace','שינוי נקודת מפגש'),
('he','meetupChangePlaceTitle','הצעת נקודת מפגש חדשה'),
('he','meetupChangePlaceBody','נקודת המפגש הנוכחית נשארת עד לאישור.'),
('he','meetupChangePlaceSent','בקשת השינוי נשלחה'),
('he','meetupChangePlacePropose','להציע את המקום הזה'),
('he','meetupChangePlaceWaiting','ממתינים ש{name} יגיב/תגיב לנקודת המפגש החדשה'),
('he','meetupChangePlaceIncomingTitle','{name} הציע/ה נקודת מפגש חדשה'),
('he','meetupChangePlaceIncomingBody','נקודת המפגש הנוכחית נשארת עד שתחליטו.'),
('he','meetupChangePlaceAccept','להשתמש במקום החדש'),
('he','meetupChangePlaceKeep','להשאיר את המקום הנוכחי'),
('he','meetupChangePlaceWithdraw','לבטל את הבקשה'),
('he','meetupChangePlaceDeclined','נקודת המפגש הנוכחית נשמרה'),
('he','meetupChangePlaceAccepted','נקודת המפגש עודכנה'),
('he','meetupChangePlaceWithdrawn','בקשת השינוי בוטלה'),
('he','meetupChangePlacePendingLabel','מקום חדש מוצע'),
('he','meetupChangePlaceNewPlace','מקום חדש: {place}'),
('he','meetupChangePlaceUnavailable','לא ניתן לשנות את נקודת המפגש במפגש הזה.'),
('he','meetupChangePlacePendingError','כבר קיימת בקשת שינוי ממתינה.'),
('he','meetupChangePlaceNoPending','אין בקשת שינוי ממתינה.'),
('he','meetupSpotMeSelfie','לצלם סלפי'),
('he','meetupSpotMeRetake','לצלם סלפי מחדש'),
('he','meetupSpotMeSelfieHint','השתמשו במצלמה הקדמית. רק התמונה משותפת.'),
('he','meetupSpotMeCameraUnavailable','המצלמה לא זמינה כאן. הוסיפו פרטי לבוש או הערה במקום.'),
('he','meetupSpotMeCameraDenied','נדרשת גישה למצלמה לצילום סלפי. אפשר להוסיף פרטי לבוש או הערה במקום.'),
('he','meetupSpotMeCaptureFailed','לא הצלחנו לצלם סלפי. נסו שוב או הוסיפו פרטים.'),
('he','meetupSpotMeHint','צלמו סלפי או שתפו מה לבשתם'),
('he','meetupOutfitColorUnspecified','לא צוין'),
('he','meetupColorBlack','שחור'),
('he','meetupColorWhite','לבן'),
('he','meetupColorGray','אפור'),
('he','meetupColorBeige','בז׳'),
('he','meetupColorBrown','חום'),
('he','meetupColorNavy','כחול כהה'),
('he','meetupColorBlue','כחול'),
('he','meetupColorLightBlue','תכלת'),
('he','meetupColorGreen','ירוק'),
('he','meetupColorOlive','זית'),
('he','meetupColorRed','אדום'),
('he','meetupColorBurgundy','בורדו'),
('he','meetupColorPink','ורוד'),
('he','meetupColorYellow','צהוב'),
('he','meetupColorOrange','כתום'),
('he','meetupColorPurple','סגול'),
('he','meetupColorGold','זהב'),
('he','meetupColorSilver','כסף'),
('he','meetupColorMulticolor','רב־צבעי'),
('he','meetupOsmAttribution','© OpenStreetMap contributors')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

NOTIFY pgrst, 'reload schema';

COMMIT;
