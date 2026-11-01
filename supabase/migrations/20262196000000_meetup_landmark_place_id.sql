-- Meet-up places: persist the Google Places id of each proposed landmark so
-- both the sender and the receiver can open that exact place's Google Maps
-- card before accepting, instead of a bare coordinate pin.
--
-- Additive only. Existing landmark rows keep place_id NULL and the client
-- falls back to a name search anchored at the coordinates. The helper's
-- signature is unchanged, so CREATE OR REPLACE is safe here (42P13 only bites
-- when an input parameter is renamed).

ALTER TABLE public.meetup_landmarks
  ADD COLUMN IF NOT EXISTS place_id TEXT;

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
  v_place_id TEXT;
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

    v_place_id := NULLIF(btrim(COALESCE(v_item->>'place_id', '')), '');
    IF v_place_id IS NOT NULL AND char_length(v_place_id) > 255 THEN
      v_place_id := NULL;
    END IF;

    IF v_category = 'custom' THEN
      -- A custom place is a name only. Never persist coordinates, distance or
      -- a provider id for it, even if a caller tries to include them.
      v_lat := NULL;
      v_lng := NULL;
      v_distance := NULL;
      v_place_id := NULL;
    ELSE
      IF v_lat IS NULL OR v_lng IS NULL
         OR v_lat < -90 OR v_lat > 90
         OR v_lng < -180 OR v_lng > 180 THEN
        RAISE EXCEPTION 'meetup_invalid_landmarks';
      END IF;
    END IF;

    INSERT INTO public.meetup_landmarks (
      session_id, match_id, proposer_id, round, label, category,
      latitude, longitude, distance_m, place_id
    ) VALUES (
      p_session_id, p_match_id, p_proposer_id, p_round, v_label, v_category,
      v_lat, v_lng, v_distance, v_place_id
    );
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_insert_landmarks(UUID, UUID, UUID, SMALLINT, JSONB) FROM PUBLIC, anon, authenticated;
