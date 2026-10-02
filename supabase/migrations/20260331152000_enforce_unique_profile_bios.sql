CREATE OR REPLACE FUNCTION public.normalize_profile_bio_text(p_bio text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(
    trim(
      regexp_replace(
        lower(
          replace(
            replace(
              replace(
                replace(COALESCE(p_bio, ''), chr(8203), ''),
                chr(8204),
                ''
              ),
              chr(8205),
              ''
            ),
            chr(65279),
            ''
          )
        ),
        '\s+',
        ' ',
        'g'
      )
    ),
    ''
  );
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
      AND public.normalize_profile_bio_text(u.bio) = v_normalized_bio
  );
END;
$$;

REVOKE ALL ON FUNCTION public.check_profile_bio_uniqueness(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_profile_bio_uniqueness(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_profile_bio_uniqueness(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.enforce_unique_profile_bio()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_old_normalized text;
  v_new_normalized text;
BEGIN
  v_new_normalized := public.normalize_profile_bio_text(NEW.bio);

  IF TG_OP = 'UPDATE' THEN
    v_old_normalized := public.normalize_profile_bio_text(OLD.bio);
    IF v_new_normalized IS NOT DISTINCT FROM v_old_normalized THEN
      RETURN NEW;
    END IF;
  END IF;

  IF v_new_normalized IS NULL THEN
    RETURN NEW;
  END IF;

  IF NOT public.check_profile_bio_uniqueness(NEW.id, NEW.bio) THEN
    RAISE EXCEPTION 'bio_already_in_use'
      USING ERRCODE = 'P0001',
            DETAIL = 'This bio is already being used by another profile.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_unique_profile_bio ON public.users;

CREATE TRIGGER trg_enforce_unique_profile_bio
BEFORE INSERT OR UPDATE OF bio ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.enforce_unique_profile_bio();

CREATE INDEX IF NOT EXISTS idx_users_normalized_bio_lookup
ON public.users (public.normalize_profile_bio_text(bio))
WHERE bio IS NOT NULL AND btrim(bio) <> '';
