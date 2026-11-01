-- Set-based photo/storage cleanup.
--
-- Problems fixed:
--   * cleanup_stale_profile_photo_refs ran every minute, paged every profile,
--     and called Storage list() once per user (an N+1 of thousands of API
--     calls per tick) from the edge function. It is now one SQL statement over
--     user_profiles + storage.objects.
--   * Both orphan and stale-ref comparisons used raw JSONB values. Photos are
--     stored as object paths, bucket-prefixed paths, or full Supabase URLs, so
--     the old comparisons could miss real references and delete/clean live
--     photos.
--   * approved_primary_photos was ignored by the orphan sweep, so a verified
--     primary photo that was not also in photos could be deleted.
--   * The sponsored-ad sweep listed the whole bucket and all creatives from
--     the edge every minute. It now asks SQL for one bounded page of orphans.
--
-- Object bytes are still deleted through the Storage API (the edge function
-- does that), because storage.protect_delete blocks direct SQL deletes.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) normalize_storage_object_path() is defined in 20262175000000 because the
--    verification-photo retention API needs it too.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- 2) Orphan profile-photo objects: unreferenced by photos or approved photos.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_orphan_profile_photos(
  p_min_age_minutes INT DEFAULT 1440,
  p_limit INT DEFAULT 500
)
RETURNS TABLE (name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_threshold TIMESTAMPTZ;
  v_limit INT;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF p_min_age_minutes IS NULL OR p_min_age_minutes < 0 THEN
    RAISE EXCEPTION 'p_min_age_minutes must be >= 0';
  END IF;

  v_limit := GREATEST(LEAST(COALESCE(p_limit, 500), 1000), 1);
  v_threshold := now() - make_interval(mins => p_min_age_minutes);

  RETURN QUERY
  WITH refs AS MATERIALIZED (
    SELECT up.user_id, v.value AS raw
    FROM public.user_profiles up
    CROSS JOIN LATERAL jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(up.photos) = 'array' THEN up.photos ELSE '[]'::jsonb END
    ) AS v(value)
    UNION ALL
    SELECT up.user_id, v.value AS raw
    FROM public.user_profiles up
    CROSS JOIN LATERAL jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(up.approved_primary_photos) = 'array'
        THEN up.approved_primary_photos ELSE '[]'::jsonb END
    ) AS v(value)
  ),
  referenced AS MATERIALIZED (
    SELECT DISTINCT names.name
    FROM (
      SELECT r.user_id,
             public.normalize_storage_object_path(r.raw, 'profile-photos') AS path
      FROM refs r
    ) n
    CROSS JOIN LATERAL (
      -- A filename-only ref may live at the bucket root (legacy) or under the
      -- user's folder (current); treat both as live references.
      VALUES
        (CASE WHEN position('/' IN n.path) = 0
          THEN n.user_id::text || '/' || n.path
          ELSE n.path END),
        (n.path)
    ) AS names(name)
    WHERE n.path IS NOT NULL
  )
  SELECT o.name
  FROM storage.objects o
  WHERE o.bucket_id = 'profile-photos'
    AND o.created_at < v_threshold
    AND NOT EXISTS (
      SELECT 1 FROM referenced r WHERE r.name = o.name
    )
  ORDER BY o.created_at
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.list_orphan_profile_photos(INT, INT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_orphan_profile_photos(INT, INT)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Stale DB refs: remove photos/approved_primary_photos entries whose object
--    is absent from storage. One statement; no per-user Storage API calls.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cleanup_stale_profile_photo_refs(
  p_limit INT DEFAULT 2000
)
RETURNS TABLE (users_updated BIGINT, refs_removed BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit INT;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_limit := GREATEST(LEAST(COALESCE(p_limit, 2000), 10000), 1);

  RETURN QUERY
  WITH refs AS MATERIALIZED (
    SELECT up.user_id, 'photos'::text AS field, v.value AS raw
    FROM public.user_profiles up
    CROSS JOIN LATERAL jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(up.photos) = 'array' THEN up.photos ELSE '[]'::jsonb END
    ) AS v(value)
    UNION ALL
    SELECT up.user_id, 'approved_primary_photos'::text AS field, v.value AS raw
    FROM public.user_profiles up
    CROSS JOIN LATERAL jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(up.approved_primary_photos) = 'array'
        THEN up.approved_primary_photos ELSE '[]'::jsonb END
    ) AS v(value)
  ),
  resolved AS MATERIALIZED (
    SELECT r.user_id, r.field, r.raw, r.object_name, r.legacy_name
    FROM (
      SELECT r.user_id, r.field, r.raw,
             CASE
               WHEN n.path IS NULL THEN NULL
               WHEN position('/' IN n.path) = 0 THEN r.user_id::text || '/' || n.path
               WHEN split_part(n.path, '/', 1) = r.user_id::text THEN n.path
               ELSE NULL  -- someone else's / unmanaged path: leave it alone
             END AS object_name,
             CASE
               WHEN n.path IS NOT NULL AND position('/' IN n.path) = 0
                 THEN n.path
               ELSE NULL
             END AS legacy_name
      FROM refs r
      CROSS JOIN LATERAL (
        SELECT public.normalize_storage_object_path(r.raw, 'profile-photos') AS path
      ) n
    ) r
  ),
  missing AS MATERIALIZED (
    SELECT DISTINCT r.user_id, r.field, r.raw
    FROM resolved r
    WHERE r.object_name IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM storage.objects o
        WHERE o.bucket_id = 'profile-photos'
          AND (o.name = r.object_name
               OR (r.legacy_name IS NOT NULL AND o.name = r.legacy_name))
      )
  ),
  affected AS MATERIALIZED (
    SELECT DISTINCT m.user_id
    FROM missing m
    LIMIT v_limit
  ),
  updated AS (
    UPDATE public.user_profiles up
    SET photos = CASE
          WHEN jsonb_typeof(up.photos) = 'array' THEN (
            SELECT COALESCE(jsonb_agg(elem ORDER BY ord), '[]'::jsonb)
            FROM jsonb_array_elements_text(up.photos) WITH ORDINALITY AS t(elem, ord)
            WHERE NOT EXISTS (
              SELECT 1 FROM missing m
              WHERE m.user_id = up.user_id
                AND m.field = 'photos'
                AND m.raw = elem
            )
          )
          ELSE up.photos
        END,
        approved_primary_photos = CASE
          WHEN jsonb_typeof(up.approved_primary_photos) = 'array' THEN (
            SELECT COALESCE(jsonb_agg(elem ORDER BY ord), '[]'::jsonb)
            FROM jsonb_array_elements_text(up.approved_primary_photos)
              WITH ORDINALITY AS t(elem, ord)
            WHERE NOT EXISTS (
              SELECT 1 FROM missing m
              WHERE m.user_id = up.user_id
                AND m.field = 'approved_primary_photos'
                AND m.raw = elem
            )
          )
          ELSE up.approved_primary_photos
        END
    WHERE EXISTS (
      SELECT 1 FROM affected a WHERE a.user_id = up.user_id
    )
    RETURNING up.user_id
  )
  SELECT
    (SELECT COUNT(*) FROM updated)::bigint,
    (
      SELECT COUNT(*)
      FROM missing m
      WHERE EXISTS (
        SELECT 1 FROM affected a WHERE a.user_id = m.user_id
      )
    )::bigint;
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_stale_profile_photo_refs(INT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_stale_profile_photo_refs(INT)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Orphan sponsored-ad images: one bounded page for the edge to remove via
--    the Storage API. External ad URLs normalize to NULL and are ignored.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_orphan_sponsored_ad_images(
  p_min_age_minutes INT DEFAULT 1440,
  p_limit INT DEFAULT 500
)
RETURNS TABLE (name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_threshold TIMESTAMPTZ;
  v_limit INT;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF p_min_age_minutes IS NULL OR p_min_age_minutes < 0 THEN
    RAISE EXCEPTION 'p_min_age_minutes must be >= 0';
  END IF;

  v_limit := GREATEST(LEAST(COALESCE(p_limit, 500), 1000), 1);
  v_threshold := now() - make_interval(mins => p_min_age_minutes);

  RETURN QUERY
  WITH referenced AS MATERIALIZED (
    SELECT DISTINCT
      public.normalize_storage_object_path(c.image_url, 'sponsored-ad-images') AS name
    FROM public.ad_creatives c
    WHERE c.image_url IS NOT NULL
      AND btrim(c.image_url) <> ''
  )
  SELECT o.name
  FROM storage.objects o
  WHERE o.bucket_id = 'sponsored-ad-images'
    AND o.created_at < v_threshold
    AND NOT EXISTS (
      SELECT 1 FROM referenced r WHERE r.name = o.name
    )
  ORDER BY o.created_at
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.list_orphan_sponsored_ad_images(INT, INT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_orphan_sponsored_ad_images(INT, INT)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 5) Remove the legacy SQL sweep. It deleted storage.objects rows directly
--    (blocked by storage.protect_delete), ignored approved_primary_photos, and
--    compared raw JSONB values. Nothing calls it: the edge task uses
--    list_orphan_profile_photos() and removes the bytes via the Storage API.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.cleanup_orphan_profile_photos(int);

COMMIT;
