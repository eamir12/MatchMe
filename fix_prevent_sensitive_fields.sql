-- Fix 1: Remove approved_primary_photos check from prevent_sensitive_user_field_updates
DROP FUNCTION IF EXISTS public.prevent_sensitive_user_field_updates() CASCADE;

CREATE OR REPLACE FUNCTION public.prevent_sensitive_user_field_updates()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF auth.role() = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF NEW.is_admin IS DISTINCT FROM OLD.is_admin THEN
    IF NEW.is_admin IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'Not allowed to set is_admin';
    END IF;
  END IF;

  IF NEW.is_verified IS DISTINCT FROM OLD.is_verified THEN
    IF NEW.is_verified IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'Not allowed to set is_verified';
    END IF;
  END IF;

  IF NEW.verification_similarity_score IS DISTINCT FROM OLD.verification_similarity_score THEN
    IF NEW.verification_similarity_score IS NOT NULL THEN
      RAISE EXCEPTION 'Not allowed to set verification_similarity_score';
    END IF;
  END IF;

  IF NEW.verification_ai_analysis IS DISTINCT FROM OLD.verification_ai_analysis THEN
    IF NEW.verification_ai_analysis IS NOT NULL THEN
      RAISE EXCEPTION 'Not allowed to set verification_ai_analysis';
    END IF;
  END IF;

  IF NEW.verification_auto_rejected IS DISTINCT FROM OLD.verification_auto_rejected THEN
    IF COALESCE(NEW.verification_auto_rejected, false) IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'Not allowed to set verification_auto_rejected';
    END IF;
  END IF;

  IF NEW.verification_reviewed_at IS DISTINCT FROM OLD.verification_reviewed_at THEN
    IF NEW.verification_reviewed_at IS NOT NULL THEN
      RAISE EXCEPTION 'Not allowed to set verification_reviewed_at';
    END IF;
  END IF;

  IF NEW.verification_reviewer_id IS DISTINCT FROM OLD.verification_reviewer_id THEN
    IF NEW.verification_reviewer_id IS NOT NULL THEN
      RAISE EXCEPTION 'Not allowed to set verification_reviewer_id';
    END IF;
  END IF;

  IF NEW.verification_status IS DISTINCT FROM OLD.verification_status THEN
    IF NEW.verification_status IN ('approved', 'rejected') THEN
      RAISE EXCEPTION 'Not allowed to set verification_status to %', NEW.verification_status;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- Re-create the trigger (name may differ per environment)
DROP TRIGGER IF EXISTS trg_prevent_sensitive_user_field_updates ON public.users;
DROP TRIGGER IF EXISTS trg_protect_sensitive_fields ON public.users;
CREATE TRIGGER trg_prevent_sensitive_user_field_updates
  BEFORE UPDATE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_sensitive_user_field_updates();

-- Fix 2: Update approve_primary_photo to use user_profiles instead of users
CREATE OR REPLACE FUNCTION public.approve_primary_photo(
  p_user_id uuid,
  p_photo_path text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_clean_path text;
  v_current jsonb;
  v_new jsonb;
BEGIN
  v_clean_path := btrim(COALESCE(p_photo_path, ''));
  IF v_clean_path = '' THEN
    RAISE EXCEPTION 'photo path required';
  END IF;

  SELECT COALESCE(up.approved_primary_photos, '[]'::jsonb)
  INTO v_current
  FROM public.user_profiles up
  WHERE up.user_id = p_user_id
  FOR UPDATE;

  v_new := to_jsonb(ARRAY(
    SELECT DISTINCT x
    FROM (
      SELECT jsonb_array_elements_text(v_current) AS x
      UNION ALL
      SELECT v_clean_path AS x
    ) t
    WHERE x IS NOT NULL AND x <> ''
  ));

  UPDATE public.user_profiles
  SET approved_primary_photos = v_new
  WHERE user_id = p_user_id;

  RETURN jsonb_build_object(
    'user_id', p_user_id,
    'photo_path', v_clean_path,
    'approved_primary_photos', v_new
  );
END;
$$;
