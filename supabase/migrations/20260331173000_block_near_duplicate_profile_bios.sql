CREATE OR REPLACE FUNCTION public.bio_texts_too_similar(
  p_left text,
  p_right text
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_left text;
  v_right text;
  v_shorter text;
  v_longer text;
  v_shorter_len integer;
  v_longer_len integer;
  v_i integer := 1;
  v_j integer := 1;
  v_mismatches integer := 0;
BEGIN
  v_left := public.normalize_profile_bio_text(p_left);
  v_right := public.normalize_profile_bio_text(p_right);

  IF v_left IS NULL OR v_right IS NULL THEN
    RETURN false;
  END IF;

  IF v_left = v_right THEN
    RETURN true;
  END IF;

  IF abs(char_length(v_left) - char_length(v_right)) > 1 THEN
    RETURN false;
  END IF;

  IF char_length(v_left) = char_length(v_right) THEN
    FOR v_i IN 1..char_length(v_left) LOOP
      IF substr(v_left, v_i, 1) <> substr(v_right, v_i, 1) THEN
        v_mismatches := v_mismatches + 1;
        IF v_mismatches > 1 THEN
          RETURN false;
        END IF;
      END IF;
    END LOOP;

    RETURN true;
  END IF;

  IF char_length(v_left) < char_length(v_right) THEN
    v_shorter := v_left;
    v_longer := v_right;
  ELSE
    v_shorter := v_right;
    v_longer := v_left;
  END IF;

  v_shorter_len := char_length(v_shorter);
  v_longer_len := char_length(v_longer);

  WHILE v_i <= v_shorter_len AND v_j <= v_longer_len LOOP
    IF substr(v_shorter, v_i, 1) = substr(v_longer, v_j, 1) THEN
      v_i := v_i + 1;
      v_j := v_j + 1;
    ELSE
      v_mismatches := v_mismatches + 1;
      IF v_mismatches > 1 THEN
        RETURN false;
      END IF;
      v_j := v_j + 1;
    END IF;
  END LOOP;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.check_profile_bio_uniqueness(
  p_user_id uuid,
  p_bio text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_normalized_bio text;
BEGIN
  v_normalized_bio := public.normalize_profile_bio_text(p_bio);

  IF v_normalized_bio IS NULL THEN
    RETURN true;
  END IF;

  RETURN NOT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id <> p_user_id
      AND public.bio_texts_too_similar(u.bio, p_bio)
  );
END;
$$;
