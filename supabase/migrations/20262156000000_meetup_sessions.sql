-- In-person meet-up: sessions, landmark options, one-sided signals and
-- ephemeral "Spot me" cards.
--
-- Privacy posture (binding, see PRIVACY_PRESERVING_DESIGN_CONSTRAINTS.md):
--   * No user coordinates are stored. Landmarks are public places chosen from
--     a one-shot location lookup on the device; the lookup itself is never
--     persisted.
--   * A meet-up row is scoped to an existing match and is readable only by
--     its two participants.
--   * Signals (wave/beacon) expire in 60/120 seconds. Spot cards expire with
--     the meet-up (max 2 hours) and are deleted when either side ends it.
--   * Only participants can read. Writes happen through SECURITY DEFINER
--     RPCs so rate limits and state transitions cannot be bypassed by a
--     modified client.
--
-- All statements are idempotent.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.meetup_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  created_by UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'proposed'
    CHECK (status IN ('proposed', 'active', 'ended')),
  origin TEXT NOT NULL DEFAULT 'proximity'
    CHECK (origin IN ('proximity', 'event')),
  proposed_by UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  proposal_round SMALLINT NOT NULL DEFAULT 1
    CHECK (proposal_round BETWEEN 1 AND 2),
  venue_zone TEXT,
  chosen_landmark_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  active_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '4 hours'),
  ended_at TIMESTAMPTZ,
  ended_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
  end_reason TEXT CHECK (end_reason IN ('found', 'cancelled', 'expired')),
  CONSTRAINT meetup_event_has_zone CHECK (
    origin <> 'event'
    OR (venue_zone IS NOT NULL AND char_length(btrim(venue_zone)) BETWEEN 1 AND 120)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS meetup_sessions_one_open_per_match
  ON public.meetup_sessions(match_id)
  WHERE status IN ('proposed', 'active');

CREATE INDEX IF NOT EXISTS idx_meetup_sessions_match_created
  ON public.meetup_sessions(match_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_meetup_sessions_expiry
  ON public.meetup_sessions(expires_at)
  WHERE status IN ('proposed', 'active');

CREATE TABLE IF NOT EXISTS public.meetup_landmarks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.meetup_sessions(id) ON DELETE CASCADE,
  match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  proposer_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  round SMALLINT NOT NULL DEFAULT 1 CHECK (round IN (1, 2)),
  label TEXT NOT NULL CHECK (char_length(btrim(label)) BETWEEN 1 AND 160),
  category TEXT NOT NULL DEFAULT 'landmark'
    CHECK (char_length(category) BETWEEN 1 AND 40),
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  distance_m INTEGER CHECK (distance_m IS NULL OR distance_m BETWEEN 0 AND 100000),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT meetup_landmark_coords_pair CHECK (
    (latitude IS NULL AND longitude IS NULL)
    OR (latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180)
  )
);

CREATE INDEX IF NOT EXISTS idx_meetup_landmarks_session
  ON public.meetup_landmarks(session_id, round, created_at);

ALTER TABLE public.meetup_sessions
  DROP CONSTRAINT IF EXISTS meetup_sessions_chosen_landmark_fk;
ALTER TABLE public.meetup_sessions
  ADD CONSTRAINT meetup_sessions_chosen_landmark_fk
  FOREIGN KEY (chosen_landmark_id)
  REFERENCES public.meetup_landmarks(id)
  ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS public.meetup_signals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.meetup_sessions(id) ON DELETE CASCADE,
  match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('wave', 'beacon')),
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  CONSTRAINT meetup_signal_expiry CHECK (expires_at > created_at)
);

CREATE INDEX IF NOT EXISTS idx_meetup_signals_session
  ON public.meetup_signals(session_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_meetup_signals_expiry
  ON public.meetup_signals(expires_at);

CREATE TABLE IF NOT EXISTS public.meetup_spot_cards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.meetup_sessions(id) ON DELETE CASCADE,
  match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('self', 'meeting_point')),
  storage_path TEXT NOT NULL,
  outfit JSONB NOT NULL DEFAULT '{}'::jsonb,
  note TEXT CHECK (note IS NULL OR char_length(note) <= 280),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  hidden_at TIMESTAMPTZ,
  deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_meetup_spot_cards_session
  ON public.meetup_spot_cards(session_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_meetup_spot_cards_expiry
  ON public.meetup_spot_cards(expires_at)
  WHERE deleted_at IS NULL;

-- DELETE payloads must carry match_id for filtered realtime subscriptions.
ALTER TABLE public.meetup_sessions REPLICA IDENTITY FULL;
ALTER TABLE public.meetup_landmarks REPLICA IDENTITY FULL;
ALTER TABLE public.meetup_signals REPLICA IDENTITY FULL;
ALTER TABLE public.meetup_spot_cards REPLICA IDENTITY FULL;

-- ---------------------------------------------------------------------------
-- 2. Participant helpers and RLS
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.meetup_match_participant(p_match_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.matches m
    WHERE m.id = p_match_id
      AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION public.meetup_session_participant(p_session_id UUID)
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
    WHERE s.id = p_session_id
      AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
  );
$$;

REVOKE ALL ON FUNCTION public.meetup_match_participant(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_session_participant(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_match_participant(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_session_participant(UUID) TO authenticated;

ALTER TABLE public.meetup_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meetup_landmarks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meetup_signals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meetup_spot_cards ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Meet-up participants read sessions" ON public.meetup_sessions;
CREATE POLICY "Meet-up participants read sessions"
  ON public.meetup_sessions FOR SELECT TO authenticated
  USING (public.meetup_match_participant(match_id));

DROP POLICY IF EXISTS "Meet-up participants read landmarks" ON public.meetup_landmarks;
CREATE POLICY "Meet-up participants read landmarks"
  ON public.meetup_landmarks FOR SELECT TO authenticated
  USING (public.meetup_match_participant(match_id));

DROP POLICY IF EXISTS "Meet-up participants read signals" ON public.meetup_signals;
CREATE POLICY "Meet-up participants read signals"
  ON public.meetup_signals FOR SELECT TO authenticated
  USING (public.meetup_match_participant(match_id));

DROP POLICY IF EXISTS "Meet-up participants read spot cards" ON public.meetup_spot_cards;
CREATE POLICY "Meet-up participants read spot cards"
  ON public.meetup_spot_cards FOR SELECT TO authenticated
  USING (public.meetup_match_participant(match_id));

REVOKE ALL ON public.meetup_sessions FROM anon, authenticated;
REVOKE ALL ON public.meetup_landmarks FROM anon, authenticated;
REVOKE ALL ON public.meetup_signals FROM anon, authenticated;
REVOKE ALL ON public.meetup_spot_cards FROM anon, authenticated;
GRANT SELECT ON public.meetup_sessions TO authenticated;
GRANT SELECT ON public.meetup_landmarks TO authenticated;
GRANT SELECT ON public.meetup_signals TO authenticated;
GRANT SELECT ON public.meetup_spot_cards TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Mutating RPCs (state + rate limits enforced server-side)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.meetup_touch_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS meetup_sessions_touch_updated_at ON public.meetup_sessions;
CREATE TRIGGER meetup_sessions_touch_updated_at
  BEFORE UPDATE ON public.meetup_sessions
  FOR EACH ROW EXECUTE FUNCTION public.meetup_touch_updated_at();

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
  IF jsonb_array_length(p_landmarks) < 1 OR jsonb_array_length(p_landmarks) > 3 THEN
    RAISE EXCEPTION 'meetup_invalid_landmarks';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_landmarks)
  LOOP
    v_label := btrim(COALESCE(v_item->>'label', ''));
    v_category := btrim(COALESCE(v_item->>'category', 'landmark'));
    IF v_label = '' OR char_length(v_label) > 160 THEN
      RAISE EXCEPTION 'meetup_invalid_landmarks';
    END IF;
    IF v_category = '' OR char_length(v_category) > 40 THEN
      v_category := 'landmark';
    END IF;

    v_lat := NULLIF(v_item->>'lat', '')::DOUBLE PRECISION;
    v_lng := NULLIF(v_item->>'lng', '')::DOUBLE PRECISION;
    IF v_lat IS NULL OR v_lng IS NULL
       OR v_lat < -90 OR v_lat > 90
       OR v_lng < -180 OR v_lng > 180 THEN
      RAISE EXCEPTION 'meetup_invalid_landmarks';
    END IF;

    BEGIN
      v_distance := NULLIF(v_item->>'distance_m', '')::INTEGER;
    EXCEPTION WHEN OTHERS THEN
      v_distance := NULL;
    END;
    IF v_distance IS NOT NULL AND (v_distance < 0 OR v_distance > 100000) THEN
      v_distance := NULL;
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

REVOKE ALL ON FUNCTION public.meetup_insert_landmarks(UUID, UUID, UUID, SMALLINT, JSONB) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.meetup_propose(
  p_match_id UUID,
  p_origin TEXT,
  p_venue_zone TEXT,
  p_landmarks JSONB DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_session public.meetup_sessions%ROWTYPE;
  v_zone TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'meetup_auth_required';
  END IF;
  IF NOT public.meetup_match_participant(p_match_id) THEN
    RAISE EXCEPTION 'meetup_not_participant';
  END IF;
  IF p_origin IS NULL OR p_origin NOT IN ('proximity', 'event') THEN
    RAISE EXCEPTION 'meetup_invalid_origin';
  END IF;

  v_zone := NULLIF(btrim(COALESCE(p_venue_zone, '')), '');
  IF p_origin = 'event' THEN
    IF v_zone IS NULL OR char_length(v_zone) > 120 THEN
      RAISE EXCEPTION 'meetup_invalid_zone';
    END IF;
  ELSE
    v_zone := NULL;
  END IF;

  -- The cleanup job runs every ten minutes. Close any stale open session
  -- first so the caller does not have to wait for it before starting again.
  UPDATE public.meetup_sessions
  SET status = 'ended',
      ended_at = now(),
      ended_by = v_uid,
      end_reason = 'expired'
  WHERE match_id = p_match_id
    AND status IN ('proposed', 'active')
    AND expires_at <= now();

  BEGIN
    INSERT INTO public.meetup_sessions (
      match_id, created_by, status, origin, proposed_by, proposal_round, venue_zone
    ) VALUES (
      p_match_id, v_uid, 'proposed', p_origin, v_uid, 1, v_zone
    )
    RETURNING * INTO v_session;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'meetup_already_active';
  END;

  IF p_origin = 'proximity' THEN
    PERFORM public.meetup_insert_landmarks(
      v_session.id, p_match_id, v_uid, 1::SMALLINT, p_landmarks
    );
  END IF;

  RETURN to_jsonb(v_session);
END;
$$;

CREATE OR REPLACE FUNCTION public.meetup_counter(
  p_session_id UUID,
  p_venue_zone TEXT,
  p_landmarks JSONB DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_session public.meetup_sessions%ROWTYPE;
  v_zone TEXT;
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
  IF v_session.status <> 'proposed' OR v_session.expires_at <= now() THEN
    RAISE EXCEPTION 'meetup_not_proposed';
  END IF;
  IF v_session.proposed_by = v_uid THEN
    RAISE EXCEPTION 'meetup_waiting_for_other';
  END IF;
  IF v_session.proposal_round >= 2 THEN
    RAISE EXCEPTION 'meetup_counter_limit';
  END IF;

  v_zone := NULLIF(btrim(COALESCE(p_venue_zone, '')), '');
  IF v_session.origin = 'event' THEN
    IF v_zone IS NULL OR char_length(v_zone) > 120 THEN
      RAISE EXCEPTION 'meetup_invalid_zone';
    END IF;
  ELSE
    v_zone := v_session.venue_zone;
  END IF;

  DELETE FROM public.meetup_landmarks
  WHERE session_id = v_session.id AND round = 2;

  IF v_session.origin = 'proximity' THEN
    PERFORM public.meetup_insert_landmarks(
      v_session.id, v_session.match_id, v_uid, 2::SMALLINT, p_landmarks
    );
  END IF;

  UPDATE public.meetup_sessions
  SET proposed_by = v_uid,
      proposal_round = 2,
      venue_zone = v_zone
  WHERE id = v_session.id
  RETURNING * INTO v_session;

  RETURN to_jsonb(v_session);
END;
$$;

CREATE OR REPLACE FUNCTION public.meetup_accept(
  p_session_id UUID,
  p_landmark_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_session public.meetup_sessions%ROWTYPE;
  v_landmark public.meetup_landmarks%ROWTYPE;
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
  IF v_session.status <> 'proposed' OR v_session.expires_at <= now() THEN
    RAISE EXCEPTION 'meetup_not_proposed';
  END IF;
  IF v_session.proposed_by = v_uid THEN
    RAISE EXCEPTION 'meetup_waiting_for_other';
  END IF;

  IF v_session.origin = 'proximity' THEN
    IF p_landmark_id IS NULL THEN
      RAISE EXCEPTION 'meetup_invalid_landmark';
    END IF;
    SELECT * INTO v_landmark
    FROM public.meetup_landmarks
    WHERE id = p_landmark_id
      AND session_id = v_session.id
      AND round = v_session.proposal_round;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'meetup_invalid_landmark';
    END IF;

    UPDATE public.meetup_sessions
    SET status = 'active',
        chosen_landmark_id = p_landmark_id,
        active_at = now(),
        expires_at = GREATEST(expires_at, now() + interval '3 hours')
    WHERE id = v_session.id
    RETURNING * INTO v_session;
  ELSE
    UPDATE public.meetup_sessions
    SET status = 'active',
        chosen_landmark_id = NULL,
        active_at = now(),
        expires_at = GREATEST(expires_at, now() + interval '3 hours')
    WHERE id = v_session.id
    RETURNING * INTO v_session;
  END IF;

  RETURN to_jsonb(v_session);
END;
$$;

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
      end_reason = v_reason
  WHERE id = v_session.id
  RETURNING * INTO v_session;

  DELETE FROM public.meetup_signals WHERE session_id = v_session.id;
  UPDATE public.meetup_spot_cards
  SET deleted_at = now()
  WHERE session_id = v_session.id AND deleted_at IS NULL;

  RETURN to_jsonb(v_session);
END;
$$;

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
  IF v_session.status <> 'active' OR v_session.expires_at <= now() THEN
    RAISE EXCEPTION 'meetup_not_active';
  END IF;

  IF p_payload IS NOT NULL AND char_length(p_payload::text) > 2000 THEN
    RAISE EXCEPTION 'meetup_invalid_signal';
  END IF;

  IF p_type = 'wave' THEN
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
    v_expires := now() + interval '120 seconds';
  ELSE
    RAISE EXCEPTION 'meetup_invalid_signal';
  END IF;

  INSERT INTO public.meetup_signals (
    session_id, match_id, sender_id, type, payload, expires_at
  ) VALUES (
    v_session.id, v_session.match_id, v_uid, p_type,
    COALESCE(p_payload, '{}'::jsonb), v_expires
  )
  RETURNING * INTO v_signal;

  RETURN to_jsonb(v_signal);
END;
$$;

-- A user can always take their own wave/beacon down early.
CREATE OR REPLACE FUNCTION public.meetup_clear_signal(
  p_session_id UUID,
  p_type TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_session public.meetup_sessions%ROWTYPE;
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
  IF p_type IS NULL OR p_type NOT IN ('wave', 'beacon') THEN
    RAISE EXCEPTION 'meetup_invalid_signal';
  END IF;

  DELETE FROM public.meetup_signals
  WHERE session_id = v_session.id
    AND sender_id = v_uid
    AND type = p_type;

  RETURN TRUE;
END;
$$;

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
  IF v_session.status <> 'active' OR v_session.expires_at <= now() THEN
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

CREATE OR REPLACE FUNCTION public.meetup_hide_spot(p_card_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_card public.meetup_spot_cards%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'meetup_auth_required';
  END IF;

  SELECT * INTO v_card FROM public.meetup_spot_cards WHERE id = p_card_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'meetup_not_found';
  END IF;
  IF NOT public.meetup_match_participant(v_card.match_id) THEN
    RAISE EXCEPTION 'meetup_not_participant';
  END IF;
  IF v_card.sender_id = v_uid THEN
    RAISE EXCEPTION 'meetup_cannot_hide_own';
  END IF;

  UPDATE public.meetup_spot_cards
  SET hidden_at = now()
  WHERE id = v_card.id;

  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.meetup_delete_spot(p_card_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_card public.meetup_spot_cards%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'meetup_auth_required';
  END IF;

  SELECT * INTO v_card FROM public.meetup_spot_cards WHERE id = p_card_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'meetup_not_found';
  END IF;
  IF v_card.sender_id <> v_uid THEN
    RAISE EXCEPTION 'meetup_not_sender';
  END IF;

  UPDATE public.meetup_spot_cards
  SET deleted_at = now()
  WHERE id = v_card.id;

  RETURN v_card.storage_path;
END;
$$;

CREATE OR REPLACE FUNCTION public.meetup_spot_paths(p_session_id UUID)
RETURNS SETOF TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT storage_path
  FROM public.meetup_spot_cards
  WHERE session_id = p_session_id
    AND public.meetup_session_participant(p_session_id);
$$;

REVOKE ALL ON FUNCTION public.meetup_propose(UUID, TEXT, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_counter(UUID, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_accept(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_end(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_signal(UUID, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_clear_signal(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_spot_share(UUID, TEXT, TEXT, JSONB, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_hide_spot(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_delete_spot(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_spot_paths(UUID) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.meetup_propose(UUID, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_counter(UUID, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_accept(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_end(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_signal(UUID, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_clear_signal(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_spot_share(UUID, TEXT, TEXT, JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_hide_spot(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_delete_spot(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_spot_paths(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Expiry cleanup
-- ---------------------------------------------------------------------------

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
      end_reason = 'expired'
  WHERE status IN ('proposed', 'active')
    AND expires_at < now();

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

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.schedule(
        'cleanup-expired-meetups',
        '*/10 * * * *',
        $cron$SELECT public.cleanup_expired_meetups();$cron$
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Could not schedule cleanup-expired-meetups: %', SQLERRM;
    END;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Realtime
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  target TEXT;
BEGIN
  FOREACH target IN ARRAY ARRAY[
    'public.meetup_sessions',
    'public.meetup_landmarks',
    'public.meetup_signals',
    'public.meetup_spot_cards'
  ]
  LOOP
    BEGIN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE %s', target);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Could not add % to supabase_realtime: %', target, SQLERRM;
    END;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Private, short-lived storage for Spot me photos
-- ---------------------------------------------------------------------------

INSERT INTO storage.buckets (id, name, public)
VALUES ('meetup-spot', 'meetup-spot', false)
ON CONFLICT (id) DO NOTHING;

UPDATE storage.buckets SET public = false WHERE id = 'meetup-spot';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'storage' AND table_name = 'buckets'
      AND column_name = 'file_size_limit'
  ) THEN
    UPDATE storage.buckets SET file_size_limit = 5242880 WHERE id = 'meetup-spot';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'storage' AND table_name = 'buckets'
      AND column_name = 'allowed_mime_types'
  ) THEN
    UPDATE storage.buckets
    SET allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]
    WHERE id = 'meetup-spot';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.meetup_storage_can_read(p_session_id TEXT)
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
      AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
  );
$$;

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
      AND s.status = 'active'
      AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
      AND p_owner_id = auth.uid()::text
  );
$$;

REVOKE ALL ON FUNCTION public.meetup_storage_can_read(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_storage_can_write(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_storage_can_read(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_storage_can_write(TEXT, TEXT) TO authenticated;

DROP POLICY IF EXISTS "Meet-up participants upload spot photos" ON storage.objects;
DROP POLICY IF EXISTS "Meet-up participants read spot photos" ON storage.objects;
DROP POLICY IF EXISTS "Meet-up participants delete spot photos" ON storage.objects;

CREATE POLICY "Meet-up participants upload spot photos" ON storage.objects
FOR INSERT TO authenticated WITH CHECK (
  bucket_id = 'meetup-spot'
  AND public.meetup_storage_can_write(
    (storage.foldername(name))[1],
    (storage.foldername(name))[2]
  )
);

CREATE POLICY "Meet-up participants read spot photos" ON storage.objects
FOR SELECT TO authenticated USING (
  bucket_id = 'meetup-spot'
  AND public.meetup_storage_can_read((storage.foldername(name))[1])
);

CREATE POLICY "Meet-up participants delete spot photos" ON storage.objects
FOR DELETE TO authenticated USING (
  bucket_id = 'meetup-spot'
  AND public.meetup_storage_can_read((storage.foldername(name))[1])
  AND (
    (storage.foldername(name))[2] = auth.uid()::text
    OR EXISTS (
      SELECT 1 FROM public.meetup_sessions s
      WHERE s.id::text = (storage.foldername(name))[1]
        AND s.status = 'ended'
    )
  )
);

-- ---------------------------------------------------------------------------
-- 7. Config
-- ---------------------------------------------------------------------------

INSERT INTO public.app_config (
  config_key, config_value, config_type, category, description,
  is_user_configurable
) VALUES
  ('meetup.session_duration_minutes', '240', 'number', 'meetup',
   'How long a meet-up session stays open before expiring', false),
  ('meetup.proposal_expiry_minutes', '240', 'number', 'meetup',
   'How long a proposed meeting point waits for an answer', false),
  ('meetup.wave_expiry_seconds', '60', 'number', 'meetup',
   'How long a wave prompt stays visible', false),
  ('meetup.beacon_expiry_seconds', '120', 'number', 'meetup',
   'How long a beacon stays on before auto-off', false),
  ('meetup.spot_card_expiry_minutes', '120', 'number', 'meetup',
   'Maximum lifetime of a Spot me card', false),
  ('meetup.spot_card_max_per_session', '5', 'number', 'meetup',
   'Maximum Spot me cards one user can share in a meet-up', false),
  ('meetup.overpass_endpoints',
   to_jsonb('https://overpass-api.de/api/interpreter,https://overpass.kumi.systems/api/interpreter,https://overpass.private.coffee/api/interpreter'::text),
   'string', 'meetup',
   'Comma-separated Overpass endpoints used for exterior landmark suggestions', false)
ON CONFLICT (config_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. UI copy (English is also bundled in the app as a fallback)
-- ---------------------------------------------------------------------------

INSERT INTO public.translations (locale, key, value) VALUES
('en','meetupTitle','Meet up'),
('en','meetupIntroBody','Choose a public place to meet. We use your current location once to look up nearby public places; your location is not saved.'),
('en','meetupPrivacyNote','Your exact location is not saved or shared with the other person. Only the public meeting point is shared.'),
('en','meetupSafetyNote','Meet in a public, well-lit place.'),
('en','meetupSuggestPlaces','Suggest meeting points'),
('en','meetupFindingPlaces','Finding public places near you…'),
('en','meetupNoPlacesFound','No suitable public places found nearby. Try again or move a little.'),
('en','meetupLandmarkLookupFailed','We could not look up nearby places right now. Try again in a moment.'),
('en','meetupRetry','Try again'),
('en','meetupOffline','Meet-up needs a connection.'),
('en','meetupLocationUnavailable','We could not get your location. Check location services and try again.'),
('en','meetupSendOptions','Send meeting points'),
('en','meetupSending','Sending…'),
('en','meetupSuggestionRoundTitle','Choose where to meet'),
('en','meetupSuggestionRoundBody','These public places are close to you. Send up to three options.'),
('en','meetupCounterRoundTitle','Suggest other places'),
('en','meetupCounterRoundBody','These public places are close to you. They can pick one, or end the meet-up.'),
('en','meetupWaitingForOther','Waiting for {name} to choose'),
('en','meetupChooseThisPlace','Meet here'),
('en','meetupSuggestOtherPlaces','Suggest other places'),
('en','meetupCounterSent','Your suggestions were sent'),
('en','meetupCounterLimit','Only one counter-suggestion is allowed.'),
('en','meetupInviteExpired','This meet-up invite expired.'),
('en','meetupActiveTitle','Meet-up active'),
('en','meetupChosenPlace','Meeting point'),
('en','meetupOpenInMaps','Open in maps'),
('en','meetupDistanceMeters','{distance} m away'),
('en','meetupDistanceKm','{distance} km away'),
('en','meetupWalkMinutes','{minutes} min walk'),
('en','meetupTimeLeft','{time} left'),
('en','meetupBeacon','Beacon'),
('en','meetupBeaconHint','Show a bright shape so they can spot you'),
('en','meetupBeaconActiveTitle','Beacon on'),
('en','meetupBeaconActiveBody','Hold up your screen. {name} is looking for this shape.'),
('en','meetupBeaconIncomingTitle','{name} is showing a beacon'),
('en','meetupBeaconIncomingBody','Look for this shape on their screen.'),
('en','meetupBeaconHide','Hide beacon'),
('en','meetupBeaconExpires','Turns off in {seconds}s'),
('en','meetupSpotMe','Spot me'),
('en','meetupSpotMeHint','Share a photo or what you are wearing'),
('en','meetupSpotMeTitle','Spot me card'),
('en','meetupSpotMePhotoSelf','Photo of me'),
('en','meetupSpotMePhotoPlace','Photo of the meeting point'),
('en','meetupSpotMeNoPhoto','No photo'),
('en','meetupSpotMePickPhoto','Add a photo (optional)'),
('en','meetupSpotMeOutfit','What you are wearing (optional)'),
('en','meetupSpotMeNote','A short clue (optional)'),
('en','meetupSpotMeNoteHint','e.g. I am by the north entrance'),
('en','meetupSpotMeShare','Share card'),
('en','meetupSpotMeSharing','Sharing…'),
('en','meetupSpotMeLimit','You shared the maximum number of cards for this meet-up.'),
('en','meetupSpotMeRateLimited','Wait a moment before sharing another card.'),
('en','meetupSpotMeIncomingTitle','{name} shared a spot card'),
('en','meetupSpotMeHide','Hide'),
('en','meetupSpotMeDelete','Delete'),
('en','meetupSpotMeReport','Report'),
('en','meetupSpotMeHidden','Spot card hidden'),
('en','meetupSpotMeReported','Report sent'),
('en','meetupSpotMeReportConfirm','Report this spot card?'),
('en','meetupSpotMeExpired','Expired'),
('en','meetupSpotMeFromYou','Your spot card'),
('en','meetupSpotMeNoDetails','No extra details'),
('en','meetupOutfitShirt','Shirt'),
('en','meetupOutfitPants','Pants'),
('en','meetupOutfitShoes','Shoes'),
('en','meetupOutfitColor','Colour'),
('en','meetupOutfitLongSleeve','Long sleeve'),
('en','meetupOutfitShortSleeve','Short sleeve'),
('en','meetupOutfitJacket','Jacket'),
('en','meetupOutfitDress','Dress'),
('en','meetupOutfitShorts','Shorts'),
('en','meetupOutfitTrousers','Trousers'),
('en','meetupOutfitSkirt','Skirt'),
('en','meetupOutfitSneakers','Sneakers'),
('en','meetupOutfitBoots','Boots'),
('en','meetupOutfitSandals','Sandals'),
('en','meetupOutfitOther','Other'),
('en','meetupWave','Wave'),
('en','meetupWaveHint','Ask them to wave so you can spot them'),
('en','meetupWaveSent','Wave sent'),
('en','meetupWaveIncomingTitle','{name} waved at you'),
('en','meetupWaveIncomingBody','Raise your hand so they can see you.'),
('en','meetupWaveBack','Wave back'),
('en','meetupWaveRateLimited','Wait a moment before waving again.'),
('en','meetupEnd','End meet-up'),
('en','meetupFound','I found them'),
('en','meetupEndConfirmTitle','End this meet-up?'),
('en','meetupEndFoundConfirmBody','This ends the meet-up for both of you and removes the beacon and spot cards.'),
('en','meetupEndCancelConfirmBody','This cancels the meet-up for both of you and removes the beacon and spot cards.'),
('en','meetupEndCancel','Cancel meet-up'),
('en','meetupCancelInvite','Cancel invite'),
('en','meetupEndedFound','Meet-up ended — they found you.'),
('en','meetupEndedByYou','You ended the meet-up.'),
('en','meetupEndedCancelled','Meet-up cancelled.'),
('en','meetupEndedExpired','Meet-up expired.'),
('en','meetupEndedOther','{name} ended the meet-up.'),
('en','meetupStartAgain','Start again'),
('en','meetupEventZonesTitle','Choose a zone at the venue'),
('en','meetupEventZonesBody','Pick a place inside or just outside the venue. No coordinates are needed.'),
('en','meetupEventZoneMainEntrance','Main entrance'),
('en','meetupEventZoneBoxOffice','Box office / ticket desk'),
('en','meetupEventZoneBar','Bar area'),
('en','meetupEventZoneCloakroom','Cloakroom'),
('en','meetupEventZoneSeating','Seating area'),
('en','meetupEventZoneCustom','Other zone'),
('en','meetupEventZoneCustomHint','e.g. Zone C bar'),
('en','meetupEventZone','Meeting zone'),
('en','meetupCategoryPark','Park'),
('en','meetupCategorySquare','Square'),
('en','meetupCategoryLandmark','Landmark'),
('en','meetupCategorySupermarket','Supermarket entrance'),
('en','meetupCategoryMall','Mall entrance'),
('en','meetupCategoryFuel','Fuel station forecourt'),
('en','meetupCategoryTransit','Transit entrance'),
('en','meetupCategoryPharmacy','Pharmacy entrance'),
('en','meetupCategoryAttraction','Tourist spot'),
('en','meetupCategoryLibrary','Public building'),
('en','meetupCategoryOther','Public place'),
('en','meetupBannerProposedByOther','{name} suggested a meeting point'),
('en','meetupBannerProposedByYou','Waiting for {name} to choose a meeting point'),
('en','meetupBannerActive','Meet-up active — {place}'),
('en','meetupBannerActiveEvent','Meet-up active — {zone}'),
('en','meetupBannerWave','{name} waved at you'),
('en','meetupBannerBeacon','{name} is showing a beacon'),
('en','meetupOpen','Open'),
('en','meetupActionFailed','Something went wrong. Try again.'),
('en','meetupProposalSent','Meeting points sent'),
('en','meetupAccepted','Meeting point confirmed'),
('en','meetupEndedToast','Meet-up ended'),
('en','meetupPlace','Meeting point'),
('en','meetupYou','You'),
('en','meetupSignalExpired','This signal expired.'),
('en','meetupCounterWaiting','Waiting for {name} to choose your suggestion'),
('en','meetupProposalWaiting','Waiting for {name}'),
('en','meetupBeaconTapHint','Tap Beacon to show a shape they can look for.'),
('en','meetupAlreadyActive','A meet-up is already active with this person.'),
('en','meetupBeaconRateLimited','Wait a moment before showing the beacon again.'),
('en','meetupBeaconExpired','This beacon expired.'),
('en','meetupSpotMeShared','Spot card shared'),
('en','meetupClose','Close'),

('es','meetupTitle','Encontrarse'),
('es','meetupIntroBody','Elige un lugar público para encontrarte. Usamos tu ubicación actual una vez para buscar lugares públicos cercanos; tu ubicación no se guarda.'),
('es','meetupPrivacyNote','Tu ubicación exacta no se guarda ni se comparte con la otra persona. Solo se comparte el punto de encuentro público.'),
('es','meetupSafetyNote','Encuéntrate en un lugar público y bien iluminado.'),
('es','meetupSuggestPlaces','Sugerir puntos de encuentro'),
('es','meetupFindingPlaces','Buscando lugares públicos cerca de ti…'),
('es','meetupNoPlacesFound','No encontramos lugares públicos adecuados cerca. Inténtalo de nuevo o muévete un poco.'),
('es','meetupLandmarkLookupFailed','No pudimos buscar lugares cercanos ahora mismo. Inténtalo de nuevo en un momento.'),
('es','meetupRetry','Intentar de nuevo'),
('es','meetupOffline','Encontrarse necesita conexión.'),
('es','meetupLocationUnavailable','No pudimos obtener tu ubicación. Revisa los servicios de ubicación e inténtalo de nuevo.'),
('es','meetupSendOptions','Enviar puntos de encuentro'),
('es','meetupSending','Enviando…'),
('es','meetupSuggestionRoundTitle','Elige dónde encontrarte'),
('es','meetupSuggestionRoundBody','Estos lugares públicos están cerca de ti. Envía hasta tres opciones.'),
('es','meetupCounterRoundTitle','Sugerir otros lugares'),
('es','meetupCounterRoundBody','Estos lugares públicos están cerca de ti. Puede elegir uno o finalizar el encuentro.'),
('es','meetupWaitingForOther','Esperando a que {name} elija'),
('es','meetupChooseThisPlace','Encontrarnos aquí'),
('es','meetupSuggestOtherPlaces','Sugerir otros lugares'),
('es','meetupCounterSent','Tus sugerencias fueron enviadas'),
('es','meetupCounterLimit','Solo se permite una contrapropuesta.'),
('es','meetupInviteExpired','Esta invitación de encuentro expiró.'),
('es','meetupActiveTitle','Encuentro activo'),
('es','meetupChosenPlace','Punto de encuentro'),
('es','meetupOpenInMaps','Abrir en mapas'),
('es','meetupDistanceMeters','A {distance} m'),
('es','meetupDistanceKm','A {distance} km'),
('es','meetupWalkMinutes','{minutes} min caminando'),
('es','meetupTimeLeft','Quedan {time}'),
('es','meetupBeacon','Baliza'),
('es','meetupBeaconHint','Muestra una forma brillante para que te vean'),
('es','meetupBeaconActiveTitle','Baliza activa'),
('es','meetupBeaconActiveBody','Levanta tu pantalla. {name} está buscando esta forma.'),
('es','meetupBeaconIncomingTitle','{name} está mostrando una baliza'),
('es','meetupBeaconIncomingBody','Busca esta forma en su pantalla.'),
('es','meetupBeaconHide','Ocultar baliza'),
('es','meetupBeaconExpires','Se apaga en {seconds} s'),
('es','meetupSpotMe','Spot me'),
('es','meetupSpotMeHint','Comparte una foto o lo que llevas puesto'),
('es','meetupSpotMeTitle','Tarjeta Spot me'),
('es','meetupSpotMePhotoSelf','Foto de mí'),
('es','meetupSpotMePhotoPlace','Foto del punto de encuentro'),
('es','meetupSpotMeNoPhoto','Sin foto'),
('es','meetupSpotMePickPhoto','Añadir una foto (opcional)'),
('es','meetupSpotMeOutfit','Lo que llevas puesto (opcional)'),
('es','meetupSpotMeNote','Una pista corta (opcional)'),
('es','meetupSpotMeNoteHint','p. ej. Estoy junto a la entrada norte'),
('es','meetupSpotMeShare','Compartir tarjeta'),
('es','meetupSpotMeSharing','Compartiendo…'),
('es','meetupSpotMeLimit','Compartiste el máximo de tarjetas para este encuentro.'),
('es','meetupSpotMeRateLimited','Espera un momento antes de compartir otra tarjeta.'),
('es','meetupSpotMeIncomingTitle','{name} compartió una tarjeta Spot me'),
('es','meetupSpotMeHide','Ocultar'),
('es','meetupSpotMeDelete','Eliminar'),
('es','meetupSpotMeReport','Denunciar'),
('es','meetupSpotMeHidden','Tarjeta oculta'),
('es','meetupSpotMeReported','Denuncia enviada'),
('es','meetupSpotMeReportConfirm','¿Denunciar esta tarjeta Spot me?'),
('es','meetupSpotMeExpired','Expirada'),
('es','meetupSpotMeFromYou','Tu tarjeta Spot me'),
('es','meetupSpotMeNoDetails','Sin detalles extra'),
('es','meetupOutfitShirt','Camisa'),
('es','meetupOutfitPants','Pantalón'),
('es','meetupOutfitShoes','Zapatos'),
('es','meetupOutfitColor','Color'),
('es','meetupOutfitLongSleeve','Manga larga'),
('es','meetupOutfitShortSleeve','Manga corta'),
('es','meetupOutfitJacket','Chaqueta'),
('es','meetupOutfitDress','Vestido'),
('es','meetupOutfitShorts','Pantalón corto'),
('es','meetupOutfitTrousers','Pantalón largo'),
('es','meetupOutfitSkirt','Falda'),
('es','meetupOutfitSneakers','Zapatillas'),
('es','meetupOutfitBoots','Botas'),
('es','meetupOutfitSandals','Sandalias'),
('es','meetupOutfitOther','Otro'),
('es','meetupWave','Saludar'),
('es','meetupWaveHint','Pídele que salude para que puedas verle'),
('es','meetupWaveSent','Saludo enviado'),
('es','meetupWaveIncomingTitle','{name} te saludó'),
('es','meetupWaveIncomingBody','Levanta la mano para que pueda verte.'),
('es','meetupWaveBack','Devolver el saludo'),
('es','meetupWaveRateLimited','Espera un momento antes de volver a saludar.'),
('es','meetupEnd','Finalizar encuentro'),
('es','meetupFound','Los encontré'),
('es','meetupEndConfirmTitle','¿Finalizar este encuentro?'),
('es','meetupEndFoundConfirmBody','Esto finaliza el encuentro para ambos y elimina la baliza y las tarjetas Spot me.'),
('es','meetupEndCancelConfirmBody','Esto cancela el encuentro para ambos y elimina la baliza y las tarjetas Spot me.'),
('es','meetupEndCancel','Cancelar encuentro'),
('es','meetupCancelInvite','Cancelar invitación'),
('es','meetupEndedFound','Encuentro finalizado: te encontraron.'),
('es','meetupEndedByYou','Finalizaste el encuentro.'),
('es','meetupEndedCancelled','Encuentro cancelado.'),
('es','meetupEndedExpired','El encuentro expiró.'),
('es','meetupEndedOther','{name} finalizó el encuentro.'),
('es','meetupStartAgain','Empezar de nuevo'),
('es','meetupEventZonesTitle','Elige una zona del recinto'),
('es','meetupEventZonesBody','Elige un lugar dentro o justo fuera del recinto. No se necesitan coordenadas.'),
('es','meetupEventZoneMainEntrance','Entrada principal'),
('es','meetupEventZoneBoxOffice','Taquilla'),
('es','meetupEventZoneBar','Zona de bar'),
('es','meetupEventZoneCloakroom','Guardarropa'),
('es','meetupEventZoneSeating','Zona de asientos'),
('es','meetupEventZoneCustom','Otra zona'),
('es','meetupEventZoneCustomHint','p. ej. Zona C bar'),
('es','meetupEventZone','Zona de encuentro'),
('es','meetupCategoryPark','Parque'),
('es','meetupCategorySquare','Plaza'),
('es','meetupCategoryLandmark','Monumento'),
('es','meetupCategorySupermarket','Entrada del supermercado'),
('es','meetupCategoryMall','Entrada del centro comercial'),
('es','meetupCategoryFuel','Gasolinera'),
('es','meetupCategoryTransit','Entrada de transporte'),
('es','meetupCategoryPharmacy','Entrada de farmacia'),
('es','meetupCategoryAttraction','Lugar turístico'),
('es','meetupCategoryLibrary','Edificio público'),
('es','meetupCategoryOther','Lugar público'),
('es','meetupBannerProposedByOther','{name} sugirió un punto de encuentro'),
('es','meetupBannerProposedByYou','Esperando a que {name} elija un punto de encuentro'),
('es','meetupBannerActive','Encuentro activo — {place}'),
('es','meetupBannerActiveEvent','Encuentro activo — {zone}'),
('es','meetupBannerWave','{name} te saludó'),
('es','meetupBannerBeacon','{name} está mostrando una baliza'),
('es','meetupOpen','Abrir'),
('es','meetupActionFailed','Algo salió mal. Inténtalo de nuevo.'),
('es','meetupProposalSent','Puntos de encuentro enviados'),
('es','meetupAccepted','Punto de encuentro confirmado'),
('es','meetupEndedToast','Encuentro finalizado'),
('es','meetupPlace','Punto de encuentro'),
('es','meetupYou','Tú'),
('es','meetupSignalExpired','Esta señal expiró.'),
('es','meetupCounterWaiting','Esperando a que {name} elija tu sugerencia'),
('es','meetupProposalWaiting','Esperando a {name}'),
('es','meetupBeaconTapHint','Toca Baliza para mostrar una forma que pueda buscar.'),
('es','meetupAlreadyActive','Ya hay un encuentro activo con esta persona.'),
('es','meetupBeaconRateLimited','Espera un momento antes de mostrar la baliza otra vez.'),
('es','meetupBeaconExpired','Esta baliza expiró.'),
('es','meetupSpotMeShared','Tarjeta compartida'),
('es','meetupClose','Cerrar'),

('he','meetupTitle','להיפגש'),
('he','meetupIntroBody','בחרו מקום ציבורי להיפגש בו. אנו משתמשים במיקומכם הנוכחי פעם אחת כדי למצוא מקומות ציבוריים בקרבת מקום; המיקום שלכם לא נשמר.'),
('he','meetupPrivacyNote','המיקום המדויק שלכם לא נשמר ולא משותף עם האדם האחר. רק נקודת המפגש הציבורית משותפת.'),
('he','meetupSafetyNote','היפגשו במקום ציבורי ומואר.'),
('he','meetupSuggestPlaces','הצעת נקודות מפגש'),
('he','meetupFindingPlaces','מחפשים מקומות ציבוריים בקרבתכם…'),
('he','meetupNoPlacesFound','לא נמצאו מקומות ציבוריים מתאימים בקרבת מקום. נסו שוב או התקדמו מעט.'),
('he','meetupLandmarkLookupFailed','לא הצלחנו לאתר מקומות בקרבת מקום כרגע. נסו שוב בעוד רגע.'),
('he','meetupRetry','נסו שוב'),
('he','meetupOffline','כדי להיפגש צריך חיבור.'),
('he','meetupLocationUnavailable','לא הצלחנו לקבל את המיקום. בדקו ששירותי המיקום פעילים ונסו שוב.'),
('he','meetupSendOptions','שליחת נקודות מפגש'),
('he','meetupSending','שולח…'),
('he','meetupSuggestionRoundTitle','בחרו היכן להיפגש'),
('he','meetupSuggestionRoundBody','המקומות הציבוריים האלה קרובים אליכם. שלחו עד שלוש אפשרויות.'),
('he','meetupCounterRoundTitle','הצעת מקומות אחרים'),
('he','meetupCounterRoundBody','המקומות הציבוריים האלה קרובים אליכם. אפשר לבחור אחד או לסיים את המפגש.'),
('he','meetupWaitingForOther','ממתינים ש{name} יבחר'),
('he','meetupChooseThisPlace','ניפגש כאן'),
('he','meetupSuggestOtherPlaces','הצעת מקומות אחרים'),
('he','meetupCounterSent','ההצעות שלכם נשלחו'),
('he','meetupCounterLimit','אפשר להציע הצעה נגדית אחת בלבד.'),
('he','meetupInviteExpired','ההזמנה למפגש פגה.'),
('he','meetupActiveTitle','המפגש פעיל'),
('he','meetupChosenPlace','נקודת מפגש'),
('he','meetupOpenInMaps','פתח במפות'),
('he','meetupDistanceMeters','{distance} מ׳ מכאן'),
('he','meetupDistanceKm','{distance} ק״מ מכאן'),
('he','meetupWalkMinutes','{minutes} דק׳ הליכה'),
('he','meetupTimeLeft','נותרו {time}'),
('he','meetupBeacon','משואה'),
('he','meetupBeaconHint','הציגו צורה בולטת כדי שיזהו אתכם'),
('he','meetupBeaconActiveTitle','המשואה פעילה'),
('he','meetupBeaconActiveBody','הרימו את המסך. {name} מחפש את הצורה הזו.'),
('he','meetupBeaconIncomingTitle','{name} מציג משואה'),
('he','meetupBeaconIncomingBody','חפשו את הצורה הזו על המסך שלו.'),
('he','meetupBeaconHide','הסתרת המשואה'),
('he','meetupBeaconExpires','תכבה בעוד {seconds} שנ׳'),
('he','meetupSpotMe','זהה אותי'),
('he','meetupSpotMeHint','שתפו תמונה או מה לבשתם'),
('he','meetupSpotMeTitle','כרטיס זהה אותי'),
('he','meetupSpotMePhotoSelf','תמונה שלי'),
('he','meetupSpotMePhotoPlace','תמונה של נקודת המפגש'),
('he','meetupSpotMeNoPhoto','ללא תמונה'),
('he','meetupSpotMePickPhoto','הוספת תמונה (אופציונלי)'),
('he','meetupSpotMeOutfit','מה לבשתם (אופציונלי)'),
('he','meetupSpotMeNote','רמז קצר (אופציונלי)'),
('he','meetupSpotMeNoteHint','למשל: אני ליד הכניסה הצפונית'),
('he','meetupSpotMeShare','שיתוף הכרטיס'),
('he','meetupSpotMeSharing','משתף…'),
('he','meetupSpotMeLimit','הגעתם למספר הכרטיסים המרבי למפגש הזה.'),
('he','meetupSpotMeRateLimited','המתינו רגע לפני שיתוף כרטיס נוסף.'),
('he','meetupSpotMeIncomingTitle','{name} שיתף כרטיס זהה אותי'),
('he','meetupSpotMeHide','הסתרה'),
('he','meetupSpotMeDelete','מחיקה'),
('he','meetupSpotMeReport','דיווח'),
('he','meetupSpotMeHidden','הכרטיס הוסתר'),
('he','meetupSpotMeReported','הדיווח נשלח'),
('he','meetupSpotMeReportConfirm','לדווח על כרטיס זה?'),
('he','meetupSpotMeExpired','פג תוקף'),
('he','meetupSpotMeFromYou','הכרטיס שלכם'),
('he','meetupSpotMeNoDetails','אין פרטים נוספים'),
('he','meetupOutfitShirt','חולצה'),
('he','meetupOutfitPants','מכנסיים'),
('he','meetupOutfitShoes','נעליים'),
('he','meetupOutfitColor','צבע'),
('he','meetupOutfitLongSleeve','שרוול ארוך'),
('he','meetupOutfitShortSleeve','שרוול קצר'),
('he','meetupOutfitJacket','מעיל'),
('he','meetupOutfitDress','שמלה'),
('he','meetupOutfitShorts','מכנסיים קצרים'),
('he','meetupOutfitTrousers','מכנסיים ארוכים'),
('he','meetupOutfitSkirt','חצאית'),
('he','meetupOutfitSneakers','סניקרס'),
('he','meetupOutfitBoots','מגפיים'),
('he','meetupOutfitSandals','סנדלים'),
('he','meetupOutfitOther','אחר'),
('he','meetupWave','נפנוף'),
('he','meetupWaveHint','בקשו מהם לנפנף כדי שתוכלו לזהות אותם'),
('he','meetupWaveSent','הנפנוף נשלח'),
('he','meetupWaveIncomingTitle','{name} ניפנף אליכם'),
('he','meetupWaveIncomingBody','הרימו יד כדי שיוכלו לראות אתכם.'),
('he','meetupWaveBack','נפנוף חזרה'),
('he','meetupWaveRateLimited','המתינו רגע לפני נפנוף נוסף.'),
('he','meetupEnd','סיום המפגש'),
('he','meetupFound','מצאתי אותם'),
('he','meetupEndConfirmTitle','לסיים את המפגש?'),
('he','meetupEndFoundConfirmBody','המפגש יסתיים לשניכם והמשואה וכרטיסי הזיהוי יימחקו.'),
('he','meetupEndCancelConfirmBody','המפגש יבוטל לשניכם והמשואה וכרטיסי הזיהוי יימחקו.'),
('he','meetupEndCancel','ביטול המפגש'),
('he','meetupCancelInvite','ביטול ההזמנה'),
('he','meetupEndedFound','המפגש הסתיים — הם מצאו אתכם.'),
('he','meetupEndedByYou','סיימתם את המפגש.'),
('he','meetupEndedCancelled','המפגש בוטל.'),
('he','meetupEndedExpired','המפגש פג תוקף.'),
('he','meetupEndedOther','{name} סיים את המפגש.'),
('he','meetupStartAgain','להתחיל שוב'),
('he','meetupEventZonesTitle','בחרו אזור במקום האירוע'),
('he','meetupEventZonesBody','בחרו מקום בתוך המקום או ממש ליד הכניסה. אין צורך בקואורדינטות.'),
('he','meetupEventZoneMainEntrance','כניסה ראשית'),
('he','meetupEventZoneBoxOffice','קופות'),
('he','meetupEventZoneBar','אזור הבר'),
('he','meetupEventZoneCloakroom','שמירת חפצים'),
('he','meetupEventZoneSeating','אזור הישיבה'),
('he','meetupEventZoneCustom','אזור אחר'),
('he','meetupEventZoneCustomHint','למשל: אזור C בר'),
('he','meetupEventZone','אזור מפגש'),
('he','meetupCategoryPark','פארק'),
('he','meetupCategorySquare','כיכר'),
('he','meetupCategoryLandmark','אתר ציון'),
('he','meetupCategorySupermarket','כניסת סופרמרקט'),
('he','meetupCategoryMall','כניסת קניון'),
('he','meetupCategoryFuel','תחנת דלק'),
('he','meetupCategoryTransit','כניסת תחבורה'),
('he','meetupCategoryPharmacy','כניסת בית מרקחת'),
('he','meetupCategoryAttraction','אתר תיירותי'),
('he','meetupCategoryLibrary','מבנה ציבורי'),
('he','meetupCategoryOther','מקום ציבורי'),
('he','meetupBannerProposedByOther','{name} הציע נקודת מפגש'),
('he','meetupBannerProposedByYou','ממתינים ש{name} יבחר נקודת מפגש'),
('he','meetupBannerActive','המפגש פעיל — {place}'),
('he','meetupBannerActiveEvent','המפגש פעיל — {zone}'),
('he','meetupBannerWave','{name} ניפנף אליכם'),
('he','meetupBannerBeacon','{name} מציג משואה'),
('he','meetupOpen','פתיחה'),
('he','meetupActionFailed','משהו השתבש. נסו שוב.'),
('he','meetupProposalSent','נקודות המפגש נשלחו'),
('he','meetupAccepted','נקודת המפגש אושרה'),
('he','meetupEndedToast','המפגש הסתיים'),
('he','meetupPlace','נקודת מפגש'),
('he','meetupYou','אתם'),
('he','meetupSignalExpired','האות פג תוקף.'),
('he','meetupCounterWaiting','ממתינים ש{name} יבחר את ההצעה שלכם'),
('he','meetupProposalWaiting','ממתינים ל{name}'),
('he','meetupBeaconTapHint','הקישו על משואה כדי להציג צורה שיוכלו לחפש.'),
('he','meetupAlreadyActive','כבר מתקיים מפגש פעיל עם האדם הזה.'),
('he','meetupBeaconRateLimited','המתינו רגע לפני הצגת המשואה שוב.'),
('he','meetupBeaconExpired','המשואה הזו פגה.'),
('he','meetupSpotMeShared','כרטיס השיתוף נשלח'),
('he','meetupClose','סגירה')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
