-- Cleanup indexes + verification-photo retention through the Storage API.
--
-- cleanup_expired_verification_photos() deleted storage.objects directly from
-- SQL. Supabase's storage.protect_delete trigger rejects that path, so the
-- 6-hourly pg_cron job has been failing and expired verification photos were
-- retained indefinitely. Storage object bytes must be removed through the
-- Storage API; the edge cron worker can do that, so the DB side now only lists
-- expired artefacts and clears the references after the API confirms removal.
--
-- Also adds the missing indexes for two table-wide cleanup deletes.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Indexes for cleanup predicates.
--
-- No created_at index for sensitive_action_email_codes: the rewrite below
-- deletes by expires_at, which 20260408000000 already indexes.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_profile_edit_requests_cleanup
  ON public.profile_edit_requests (created_at)
  WHERE status IN ('approved', 'rejected');

CREATE INDEX IF NOT EXISTS idx_users_verification_retention
  ON public.users (verification_photo_retention_until)
  WHERE verification_photo_path IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2) Normalize any accepted storage reference to a bucket-relative object
--    name: object path, bucket-prefixed path, or Supabase public/sign/render
--    URL. Returns NULL for external URLs, which must never be treated as ours.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.normalize_storage_object_path(
  p_value TEXT,
  p_bucket TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog
AS $$
DECLARE
  v_value TEXT;
  v_bucket TEXT;
BEGIN
  v_bucket := btrim(COALESCE(p_bucket, ''));
  IF v_bucket = '' THEN
    RETURN NULL;
  END IF;

  v_value := btrim(COALESCE(p_value, ''));
  IF v_value = '' THEN
    RETURN NULL;
  END IF;

  -- Signed/public/render URLs carry tokens, width params, or fragments.
  v_value := regexp_replace(v_value, '[?#].*$', '');

  IF v_value ~* '^https?://' THEN
    -- Only Supabase Storage URLs are ours:
    --   /storage/v1/object/{public|authenticated|sign}/<bucket>/<object>
    --   /storage/v1/render/image/{public|authenticated|sign}/<bucket>/<object>
    -- A bare "/<bucket>/" match would also normalize arbitrary external URLs
    -- that happen to contain the bucket name in their path.
    IF v_value !~* '^https?://[^/]+/storage/v1/(object|render/image)/(public|authenticated|sign)/' THEN
      RETURN NULL;
    END IF;
    v_value := regexp_replace(
      v_value,
      '^https?://[^/]+/storage/v1/(object|render/image)/(public|authenticated|sign)/',
      ''
    );
    IF v_value LIKE v_bucket || '/%' THEN
      v_value := substr(v_value, length(v_bucket) + 2);
    ELSE
      RETURN NULL;  -- URL for a different bucket
    END IF;
  ELSE
    v_value := ltrim(v_value, '/');
    IF v_value LIKE v_bucket || '/%' THEN
      v_value := substr(v_value, length(v_bucket) + 2);
    END IF;
  END IF;

  RETURN NULLIF(btrim(v_value), '');
END;
$$;

REVOKE ALL ON FUNCTION public.normalize_storage_object_path(TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.normalize_storage_object_path(TEXT, TEXT)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Email-code cleanup keyed off expiry, not creation.
-- ---------------------------------------------------------------------------
-- The old body keyed off created_at while the table is indexed by
-- expires_at; use the expiry itself so rows disappear exactly when invalid.
CREATE OR REPLACE FUNCTION public.cleanup_expired_email_codes()
RETURNS TABLE (deleted_count int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted_count int;
BEGIN
  DELETE FROM public.sensitive_action_email_codes
  WHERE expires_at < now();

  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  RETURN QUERY SELECT v_deleted_count;
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_expired_email_codes() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cleanup_expired_email_codes() FROM anon;
REVOKE ALL ON FUNCTION public.cleanup_expired_email_codes() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_email_codes() TO service_role;

-- ---------------------------------------------------------------------------
-- 4) List expired verification photos (service role only).
--    Normalizes legacy URL / bucket-prefixed values to an object name.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_expired_verification_photos(p_limit INT DEFAULT 200)
RETURNS TABLE (user_id uuid, storage_path text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  RETURN QUERY
  SELECT u.id, p.storage_path
  FROM public.users u
  CROSS JOIN LATERAL (
    SELECT public.normalize_storage_object_path(
      u.verification_photo_path, 'verification-photos'
    ) AS storage_path
  ) p
  WHERE u.verification_photo_path IS NOT NULL
    AND u.verification_photo_retention_until IS NOT NULL
    AND u.verification_photo_retention_until <= now()
    AND p.storage_path IS NOT NULL
  ORDER BY u.verification_photo_retention_until
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
END;
$$;

REVOKE ALL ON FUNCTION public.list_expired_verification_photos(INT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_expired_verification_photos(INT) FROM anon;
REVOKE ALL ON FUNCTION public.list_expired_verification_photos(INT) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.list_expired_verification_photos(INT) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) Clear references after Storage API removal. Only touches rows whose
--    retention is still expired (a re-upload resets retention_until).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clear_expired_verification_photo_paths(p_items JSONB)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item JSONB;
  v_count INTEGER := 0;
  v_updated INTEGER;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb))
  LOOP
    UPDATE public.users
    SET verification_photo_path = NULL
    WHERE id = NULLIF(item ->> 'user_id', '')::uuid
      AND verification_photo_path IS NOT NULL
      AND verification_photo_retention_until IS NOT NULL
      AND verification_photo_retention_until <= now();

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    v_count := v_count + v_updated;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.clear_expired_verification_photo_paths(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.clear_expired_verification_photo_paths(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.clear_expired_verification_photo_paths(JSONB) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.clear_expired_verification_photo_paths(JSONB) TO service_role;

-- ---------------------------------------------------------------------------
-- 6) Retire the direct-SQL pg_cron job and its helpers.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_jobid bigint;
BEGIN
  IF to_regclass('cron.job') IS NULL THEN
    RETURN;
  END IF;

  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'verification-photo-cleanup';
  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
    RAISE NOTICE 'Unscheduled verification-photo-cleanup (jobid %)', v_jobid;
  END IF;
END;
$$;

DROP FUNCTION IF EXISTS public.scheduled_verification_photo_cleanup();
DROP FUNCTION IF EXISTS public.cleanup_expired_verification_photos();

-- ---------------------------------------------------------------------------
-- 7) Return the deleted row count from the profile-edit-request cleanup. The
--    old version returned void, so the edge task always logged deletedCount=0.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.cleanup_old_profile_edit_requests();
CREATE OR REPLACE FUNCTION public.cleanup_old_profile_edit_requests()
RETURNS TABLE (deleted_count int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted INT;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  DELETE FROM public.profile_edit_requests
  WHERE status IN ('approved', 'rejected')
    AND created_at < now() - interval '30 days';

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN QUERY SELECT v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_old_profile_edit_requests()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_old_profile_edit_requests()
  TO service_role;

COMMIT;
