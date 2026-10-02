-- ============================================================================
-- Fix: Admin reset of verification status leaves stale data that blocks resubmit
--
-- Root cause:
--   admin_set_user_verification_status(p_user_id, 'unverified') only reset
--   verification_status / is_verified / reviewed_at / reviewer / retention.
--   It left behind:
--     verification_photo_path, verification_submitted_at,
--     verification_similarity_score, verification_ai_analysis,
--     verification_auto_rejected, verification_reference_artifact, etc.
--   plus the old file in the verification-photos bucket.
--
--   The MatchMe app previously gated the submit button on a stale cached
--   profile (pending) instead of the fresh server status, so after a reset
--   the form showed (fresh=unverified) but the button stayed disabled
--   (cached=pending). The user-app fix makes the button use the fresh status,
--   but the server should still return a clean `unverified` row so resubmit
--   starts fresh (matching supabase/scripts/reset_user_verification.sql and
--   supabase/clean_verification_data.sql).
--
-- Fix:
--   On reset to 'unverified', clear all transient verification artifacts and
--   delete the user's old objects from the verification-photos bucket.
--   Other statuses keep existing behavior.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_set_user_verification_status(
  p_user_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_status text;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_status := NULLIF(trim(p_status), '');
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'p_status is required';
  END IF;

  IF v_status NOT IN ('unverified', 'analyzing', 'pending', 'approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid status';
  END IF;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  IF v_status = 'unverified' THEN
    -- Clean reset: clear transient artifacts so the user can resubmit fresh.
    UPDATE public.users u
    SET
      verification_status = v_status,
      is_verified = false,
      verification_photo_path = NULL,
      verification_submitted_at = NULL,
      verification_reviewed_at = NULL,
      verification_reviewer_id = NULL,
      verification_similarity_score = NULL,
      verification_ai_analysis = NULL,
      verification_auto_rejected = NULL,
      verification_reference_artifact = NULL,
      verification_reference_generated_at = NULL,
      verification_photo_retention_until = NULL
    WHERE u.id = p_user_id;

    -- Remove orphaned verification photo(s) for this user.
    -- Verification photos are stored as "<userId>/verification.jpg".
    BEGIN
      DELETE FROM storage.objects
      WHERE bucket_id = 'verification-photos'
        AND name LIKE p_user_id::text || '/%';
    EXCEPTION WHEN others THEN
      -- Storage cleanup is best-effort; don't fail the reset if it errors
      -- (e.g. missing privileges on some deployments).
      RAISE WARNING 'admin reset: could not delete verification-photos for %: %', p_user_id, SQLERRM;
    END;
  ELSE
    UPDATE public.users u
    SET
      verification_status = v_status,
      is_verified = (v_status = 'approved'),
      verification_reviewed_at = CASE WHEN v_status IN ('approved', 'rejected') THEN now() ELSE NULL END,
      verification_reviewer_id = CASE WHEN v_status IN ('approved', 'rejected') THEN auth.uid() ELSE NULL END,
      verification_photo_retention_until = CASE
        WHEN v_status = 'approved' THEN now() + interval '30 days'
        WHEN v_status = 'pending' THEN now() + interval '14 days'
        WHEN v_status = 'rejected' THEN now() + interval '7 days'
        ELSE NULL
      END
    WHERE u.id = p_user_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_user_verification_status(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_user_verification_status(uuid, text) TO service_role;

COMMIT;
