BEGIN;

DROP FUNCTION IF EXISTS public.list_orphan_profile_photos(int,int);

CREATE OR REPLACE FUNCTION public.list_orphan_profile_photos(
  p_min_age_minutes int DEFAULT 1440,
  p_limit int DEFAULT 500
)
RETURNS TABLE (name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_threshold timestamptz;
  v_limit int;
BEGIN
  IF p_min_age_minutes IS NULL OR p_min_age_minutes < 0 THEN
    RAISE EXCEPTION 'p_min_age_minutes must be >= 0';
  END IF;

  v_limit := COALESCE(p_limit, 500);
  IF v_limit < 1 THEN v_limit := 1; END IF;
  IF v_limit > 1000 THEN v_limit := 1000; END IF;

  v_threshold := now() - make_interval(mins => p_min_age_minutes);

  RETURN QUERY
  WITH referenced AS (
    SELECT DISTINCT value AS name
    FROM public.users u
    CROSS JOIN LATERAL jsonb_array_elements_text(to_jsonb(u.photos)) AS value
    WHERE u.photos IS NOT NULL
      AND value IS NOT NULL
      AND btrim(value) <> ''
  )
  SELECT o.name
  FROM storage.objects o
  WHERE o.bucket_id = 'profile-photos'
    AND o.created_at < v_threshold
    AND NOT EXISTS (
      SELECT 1
      FROM referenced r
      WHERE r.name = o.name
    )
  ORDER BY o.created_at ASC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.list_orphan_profile_photos(int,int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_orphan_profile_photos(int,int) TO service_role;

COMMIT;

