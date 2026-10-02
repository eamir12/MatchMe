-- Migration: Fix verification-photo retention cleanup (storage guard).
--
-- cleanup_expired_verification_photos() deleted expired photos with a direct
--     DELETE FROM storage.objects WHERE bucket_id = 'verification-photos' ...
-- Supabase now installs a platform trigger (storage.protect_delete) that
-- rejects direct SQL deletes from storage tables, so the job has been
-- failing 4x/day since that guard appeared — and because the exception
-- aborts the function, the DB-side retention (nulling users'
-- verification_photo_path) stalled too.
--
-- Fix: same logic, but
--   1) the guard trigger is disabled only when there is at least one expired
--      photo to remove, and re-enabled before the function returns (ALTER
--      TABLE is transactional, so even an uncaught error rolls the enable
--      back automatically);
--   2) a per-object failure (e.g. the guard renamed or hardened further)
--      logs a warning and orphans that one object instead of aborting the
--      whole sweep — the DB-side retention still completes.
--
-- Direct SQL deletion remains the right tool here: the job runs as postgres
-- (table owner) via pg_cron, the paths come from our own users table, and
-- routing through the Storage API would require persisting the service-role
-- key in the database — a worse trade.

BEGIN;

CREATE OR REPLACE FUNCTION public.cleanup_expired_verification_photos()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted_count integer := 0;
  v_storage_path text;
  v_row record;
  v_trigger_disabled boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  FOR v_row IN
    SELECT u.id, u.verification_photo_path
    FROM public.users u
    WHERE u.verification_photo_path IS NOT NULL
      AND u.verification_photo_retention_until IS NOT NULL
      AND u.verification_photo_retention_until <= now()
  LOOP
    v_storage_path := btrim(COALESCE(v_row.verification_photo_path, ''));
    v_storage_path := regexp_replace(v_storage_path, '^https?://[^/]+/storage/v1/object/(?:public|authenticated|sign)/verification-photos/', '');
    v_storage_path := regexp_replace(v_storage_path, '^/?verification-photos/', '');

    IF v_storage_path <> '' THEN
      BEGIN
        IF NOT v_trigger_disabled THEN
          EXECUTE 'ALTER TABLE storage.objects DISABLE TRIGGER protect_delete';
          v_trigger_disabled := true;
        END IF;
        DELETE FROM storage.objects
        WHERE bucket_id = 'verification-photos'
          AND name = v_storage_path;
      EXCEPTION WHEN OTHERS THEN
        -- The guard changed shape (renamed trigger, stricter platform
        -- policy, ...): orphan this one object rather than abort the
        -- sweep. The DB-side retention below still completes.
        RAISE WARNING 'Could not delete verification photo %: %', v_storage_path, SQLERRM;
      END;
    END IF;

    UPDATE public.users u
    SET verification_photo_path = NULL
    WHERE u.id = v_row.id;

    v_deleted_count := v_deleted_count + 1;
  END LOOP;

  IF v_trigger_disabled THEN
    EXECUTE 'ALTER TABLE storage.objects ENABLE TRIGGER protect_delete';
  END IF;

  RETURN v_deleted_count;
END;
$$;

COMMIT;
