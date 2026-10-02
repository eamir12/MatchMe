BEGIN;

ALTER TABLE public.users
ADD COLUMN IF NOT EXISTS verification_reference_artifact jsonb,
ADD COLUMN IF NOT EXISTS verification_reference_generated_at timestamptz,
ADD COLUMN IF NOT EXISTS verification_photo_retention_until timestamptz;

COMMENT ON COLUMN public.users.verification_reference_artifact IS 'Derived non-image verification reference metadata used for fraud prevention after verification review';
COMMENT ON COLUMN public.users.verification_reference_generated_at IS 'When the derived verification reference artifact was generated';
COMMENT ON COLUMN public.users.verification_photo_retention_until IS 'When the raw verification photo should no longer be retained';

CREATE OR REPLACE FUNCTION public.block_protected_user_fields_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  jwt_role text;
  v_is_admin boolean;
BEGIN
  jwt_role := current_setting('request.jwt.claim.role', true);

  IF jwt_role IS NULL THEN
    RETURN NEW;
  END IF;

  IF jwt_role = 'service_role' THEN
    RETURN NEW;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF COALESCE(v_is_admin, false) THEN
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
    NEW.verification_reference_artifact IS DISTINCT FROM OLD.verification_reference_artifact OR
    NEW.verification_reference_generated_at IS DISTINCT FROM OLD.verification_reference_generated_at OR
    NEW.verification_photo_retention_until IS DISTINCT FROM OLD.verification_photo_retention_until OR
    NEW.approved_primary_photos IS DISTINCT FROM OLD.approved_primary_photos
  ) THEN
    RAISE EXCEPTION 'protected_user_fields_update_not_allowed';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_block_protected_user_fields_update ON public.users;
CREATE TRIGGER trg_block_protected_user_fields_update
BEFORE UPDATE ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.block_protected_user_fields_update();

CREATE OR REPLACE FUNCTION public.edge_update_verification(
  p_user_id uuid,
  p_patch jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_patch jsonb := COALESCE(p_patch, '{}'::jsonb);
  v_status text;
BEGIN
  PERFORM public.edge_require_internal_secret();

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_id_required';
  END IF;

  IF jsonb_typeof(v_patch) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'invalid_patch';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_object_keys(v_patch) k
    WHERE k NOT IN (
      'verification_photo_path',
      'verification_status',
      'verification_submitted_at',
      'verification_reviewed_at',
      'verification_similarity_score',
      'verification_ai_analysis',
      'verification_auto_rejected',
      'verification_reference_artifact',
      'verification_reference_generated_at',
      'verification_photo_retention_until',
      'is_verified'
    )
  ) THEN
    RAISE EXCEPTION 'patch_has_disallowed_keys';
  END IF;

  v_status := NULLIF(btrim(COALESCE(v_patch ->> 'verification_status', '')), '');
  IF v_status IS NOT NULL AND v_status NOT IN ('pending', 'analyzing', 'approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid_verification_status';
  END IF;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  UPDATE public.users u
  SET
    verification_photo_path = CASE
      WHEN v_patch ? 'verification_photo_path' THEN NULLIF(btrim(COALESCE(v_patch ->> 'verification_photo_path', '')), '')
      ELSE u.verification_photo_path
    END,
    verification_status = CASE
      WHEN v_patch ? 'verification_status' THEN v_status
      ELSE u.verification_status
    END,
    verification_submitted_at = CASE
      WHEN v_patch ? 'verification_submitted_at' THEN NULLIF(v_patch ->> 'verification_submitted_at', '')::timestamptz
      ELSE u.verification_submitted_at
    END,
    verification_reviewed_at = CASE
      WHEN v_patch ? 'verification_reviewed_at' THEN NULLIF(v_patch ->> 'verification_reviewed_at', '')::timestamptz
      ELSE u.verification_reviewed_at
    END,
    verification_similarity_score = CASE
      WHEN v_patch ? 'verification_similarity_score' THEN NULLIF(v_patch ->> 'verification_similarity_score', '')::numeric
      ELSE u.verification_similarity_score
    END,
    verification_ai_analysis = CASE
      WHEN v_patch ? 'verification_ai_analysis' THEN COALESCE(v_patch -> 'verification_ai_analysis', 'null'::jsonb)
      ELSE u.verification_ai_analysis
    END,
    verification_auto_rejected = CASE
      WHEN v_patch ? 'verification_auto_rejected' THEN COALESCE((v_patch ->> 'verification_auto_rejected')::boolean, false)
      ELSE u.verification_auto_rejected
    END,
    verification_reference_artifact = CASE
      WHEN v_patch ? 'verification_reference_artifact' THEN COALESCE(v_patch -> 'verification_reference_artifact', 'null'::jsonb)
      ELSE u.verification_reference_artifact
    END,
    verification_reference_generated_at = CASE
      WHEN v_patch ? 'verification_reference_generated_at' THEN NULLIF(v_patch ->> 'verification_reference_generated_at', '')::timestamptz
      ELSE u.verification_reference_generated_at
    END,
    verification_photo_retention_until = CASE
      WHEN v_patch ? 'verification_photo_retention_until' THEN NULLIF(v_patch ->> 'verification_photo_retention_until', '')::timestamptz
      ELSE u.verification_photo_retention_until
    END,
    is_verified = CASE
      WHEN v_patch ? 'is_verified' THEN COALESCE((v_patch ->> 'is_verified')::boolean, false)
      ELSE u.is_verified
    END
  WHERE u.id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user_not_found';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.edge_update_verification(uuid, jsonb) TO anon, authenticated;

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
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_user_verification_status(uuid, text) TO authenticated;

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
      DELETE FROM storage.objects
      WHERE bucket_id = 'verification-photos'
        AND name = v_storage_path;
    END IF;

    UPDATE public.users u
    SET verification_photo_path = NULL
    WHERE u.id = v_row.id;

    v_deleted_count := v_deleted_count + 1;
  END LOOP;

  RETURN v_deleted_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.scheduled_verification_photo_cleanup()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.cleanup_expired_verification_photos();
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'verification-photo-cleanup') THEN
      PERFORM cron.schedule(
        'verification-photo-cleanup',
        '15 */6 * * *',
        'SELECT public.scheduled_verification_photo_cleanup()'
      );
    END IF;
  END IF;
END$$;

UPDATE translations
SET value = 'Your verification photo is used for verification and fraud prevention, stays private, and is kept only as long as needed for review and community safety. After that, we keep only derived fraud-prevention signals.',
    updated_at = now()
WHERE key = 'verificationPrivacyNotice' AND locale = 'en';

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'verificationPrivacyNotice', 'Your verification photo is used for verification and fraud prevention, stays private, and is kept only as long as needed for review and community safety. After that, we keep only derived fraud-prevention signals.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'verificationPrivacyNotice' AND locale = 'en');

UPDATE translations
SET value = 'Tu foto de verificación se usa para la verificación y la prevención del fraude, permanece privada y se conserva solo durante el tiempo necesario para la revisión y la seguridad de la comunidad. Después, solo conservamos señales derivadas para prevenir el fraude.',
    updated_at = now()
WHERE key = 'verificationPrivacyNotice' AND locale = 'es';

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'verificationPrivacyNotice', 'Tu foto de verificación se usa para la verificación y la prevención del fraude, permanece privada y se conserva solo durante el tiempo necesario para la revisión y la seguridad de la comunidad. Después, solo conservamos señales derivadas para prevenir el fraude.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'verificationPrivacyNotice' AND locale = 'es');

UPDATE translations
SET value = 'תמונת האימות שלך משמשת לאימות ולמניעת הונאות, נשארת פרטית, ונשמרת רק כל עוד יש בכך צורך לצורכי בדיקה ובטיחות הקהילה. לאחר מכן נשמרים רק אותות נגזרים למניעת הונאות.',
    updated_at = now()
WHERE key = 'verificationPrivacyNotice' AND locale = 'he';

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'verificationPrivacyNotice', 'תמונת האימות שלך משמשת לאימות ולמניעת הונאות, נשארת פרטית, ונשמרת רק כל עוד יש בכך צורך לצורכי בדיקה ובטיחות הקהילה. לאחר מכן נשמרים רק אותות נגזרים למניעת הונאות.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'verificationPrivacyNotice' AND locale = 'he');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'primaryPhotoVerificationErrorReferenceExpired', 'Please re-verify your profile before changing your primary photo.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorReferenceExpired' AND locale = 'en');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'primaryPhotoVerificationErrorReferenceExpired', 'Vuelve a verificar tu perfil antes de cambiar tu foto principal.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorReferenceExpired' AND locale = 'es');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'primaryPhotoVerificationErrorReferenceExpired', 'יש לאמת מחדש את הפרופיל שלך לפני שינוי התמונה הראשית.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorReferenceExpired' AND locale = 'he');

COMMIT;
