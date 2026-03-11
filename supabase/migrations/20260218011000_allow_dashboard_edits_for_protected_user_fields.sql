BEGIN;

CREATE OR REPLACE FUNCTION public.block_protected_user_fields_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  jwt_role text;
BEGIN
  jwt_role := current_setting('request.jwt.claim.role', true);

  IF jwt_role IS NULL THEN
    RETURN NEW;
  END IF;

  IF jwt_role = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF (
    NEW.is_verified IS DISTINCT FROM OLD.is_verified OR
    NEW.verification_status IS DISTINCT FROM OLD.verification_status OR
    NEW.verification_photo_path IS DISTINCT FROM OLD.verification_photo_path OR
    NEW.verification_submitted_at IS DISTINCT FROM OLD.verification_submitted_at OR
    NEW.verification_reviewed_at IS DISTINCT FROM OLD.verification_reviewed_at OR
    NEW.verification_reviewer_id IS DISTINCT FROM OLD.verification_reviewer_id OR
    NEW.verification_similarity_score IS DISTINCT FROM OLD.verification_similarity_score OR
    NEW.verification_ai_analysis IS DISTINCT FROM OLD.verification_ai_analysis OR
    NEW.verification_auto_rejected IS DISTINCT FROM OLD.verification_auto_rejected OR
    NEW.approved_primary_photos IS DISTINCT FROM OLD.approved_primary_photos
  ) THEN
    RAISE EXCEPTION 'protected_user_fields_update_not_allowed';
  END IF;

  RETURN NEW;
END;
$$;

COMMIT;
