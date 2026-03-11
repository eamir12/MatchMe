BEGIN;

DROP FUNCTION IF EXISTS public.cleanup_orphan_profile_photos(int);

CREATE OR REPLACE FUNCTION public.cleanup_orphan_profile_photos(p_min_age_minutes int DEFAULT 1440)
RETURNS TABLE (deleted_count int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_threshold timestamptz;
  v_deleted int := 0;
BEGIN
  IF p_min_age_minutes IS NULL OR p_min_age_minutes < 0 THEN
    RAISE EXCEPTION 'p_min_age_minutes must be >= 0';
  END IF;

  v_threshold := now() - make_interval(mins => p_min_age_minutes);

  WITH referenced AS (
    SELECT DISTINCT value AS name
    FROM public.users u
    CROSS JOIN LATERAL jsonb_array_elements_text(to_jsonb(u.photos)) AS value
    WHERE u.photos IS NOT NULL
      AND value IS NOT NULL
      AND btrim(value) <> ''
    UNION
    SELECT DISTINCT value AS name
    FROM public.users u
    CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(u.approved_primary_photos, '[]'::jsonb)) AS value
    WHERE value IS NOT NULL
      AND btrim(value) <> ''
  )
  DELETE FROM storage.objects o
  WHERE o.bucket_id = 'profile-photos'
    AND o.created_at < v_threshold
    AND NOT EXISTS (
      SELECT 1
      FROM referenced r
      WHERE r.name = o.name
    );

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  deleted_count := v_deleted;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_orphan_profile_photos(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cleanup_orphan_profile_photos(int) TO service_role;

COMMIT;
