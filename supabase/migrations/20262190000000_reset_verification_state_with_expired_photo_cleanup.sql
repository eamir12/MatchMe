-- Reset the verification state when the retention sweep deletes the selfie.
--
-- clear_expired_verification_photo_paths() runs right after the cron worker
-- removes expired objects from the verification-photos bucket. It used to
-- only null verification_photo_path, which left the row in a dead state: the
-- status card said "rejected" (or "under review") while the evidence photo
-- was gone, and the user could not start over.
--
-- Now, for every row whose path is cleared:
--   * rejected / pending / analyzing -> full clean reset to 'unverified'
--     (the same reset admin_set_user_verification_status('unverified')
--     performs), in the same statement that clears the path. Without the
--     photo the state can never be decided, so the user is invited to
--     verify again instead of staring at a stale rejection.
--   * approved -> keeps verification_status = 'approved' and is_verified;
--     an approval stands after the 30-day photo retention ends, only the
--     path is dropped.
--
-- The one-time backfill repairs users already stuck from earlier sweeps
-- (path null, retention expired, non-approved status). That includes the
-- 2026-10-20 auto-rejection whose selfie was purged on 2026-10-27.

BEGIN;

CREATE OR REPLACE FUNCTION public.clear_expired_verification_photo_paths(p_items JSONB)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER := 0;
  v_updated INTEGER;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  -- The protected-fields trigger lets service_role through.
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  -- Rows the sweep may still clear: a re-upload resets the retention window,
  -- so an expired row whose path is still set is genuinely purged evidence.
  WITH items AS (
    SELECT DISTINCT NULLIF(item ->> 'user_id', '')::uuid AS user_id
    FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) AS item
  )
  UPDATE public.users u
  SET
    verification_status = 'unverified',
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
  FROM items i
  WHERE u.id = i.user_id
    AND u.verification_photo_path IS NOT NULL
    AND u.verification_photo_retention_until IS NOT NULL
    AND u.verification_photo_retention_until <= now()
    AND u.verification_status IS DISTINCT FROM 'approved';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  v_count := v_count + v_updated;

  WITH items AS (
    SELECT DISTINCT NULLIF(item ->> 'user_id', '')::uuid AS user_id
    FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) AS item
  )
  UPDATE public.users u
  SET verification_photo_path = NULL
  FROM items i
  WHERE u.id = i.user_id
    AND u.verification_photo_path IS NOT NULL
    AND u.verification_photo_retention_until IS NOT NULL
    AND u.verification_photo_retention_until <= now()
    AND u.verification_status = 'approved';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  v_count := v_count + v_updated;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.clear_expired_verification_photo_paths(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.clear_expired_verification_photo_paths(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.clear_expired_verification_photo_paths(JSONB) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.clear_expired_verification_photo_paths(JSONB) TO service_role;

-- One-time repair of rows the old sweep already left without a photo.
UPDATE public.users u
SET
  verification_status = 'unverified',
  is_verified = false,
  verification_submitted_at = NULL,
  verification_reviewed_at = NULL,
  verification_reviewer_id = NULL,
  verification_similarity_score = NULL,
  verification_ai_analysis = NULL,
  verification_auto_rejected = NULL,
  verification_reference_artifact = NULL,
  verification_reference_generated_at = NULL,
  verification_photo_retention_until = NULL
WHERE u.verification_status IN ('rejected', 'pending', 'analyzing')
  AND u.verification_photo_path IS NULL
  AND u.verification_photo_retention_until IS NOT NULL
  AND u.verification_photo_retention_until <= now();

COMMIT;
