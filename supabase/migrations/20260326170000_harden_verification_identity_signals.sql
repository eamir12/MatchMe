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

  UPDATE public.users u
  SET
    verification_status = v_status,
    is_verified = (v_status = 'approved'),
    verification_reviewed_at = CASE WHEN v_status IN ('approved', 'rejected') THEN now() ELSE NULL END,
    verification_reviewer_id = CASE WHEN v_status IN ('approved', 'rejected') THEN auth.uid() ELSE NULL END
  WHERE u.id = p_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_user_verification_status(uuid, text) TO authenticated;

UPDATE translations
SET value = 'Your verification photo is used for verification and fraud prevention, stays private, and may be retained securely to help protect the community.',
    updated_at = now()
WHERE key = 'verificationPrivacyNotice' AND locale = 'en';

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'verificationPrivacyNotice', 'Your verification photo is used for verification and fraud prevention, stays private, and may be retained securely to help protect the community.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'verificationPrivacyNotice' AND locale = 'en');

UPDATE translations
SET value = 'Tu foto de verificación se usa para la verificación y la prevención del fraude, permanece privada y puede conservarse de forma segura para ayudar a proteger a la comunidad.',
    updated_at = now()
WHERE key = 'verificationPrivacyNotice' AND locale = 'es';

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'verificationPrivacyNotice', 'Tu foto de verificación se usa para la verificación y la prevención del fraude, permanece privada y puede conservarse de forma segura para ayudar a proteger a la comunidad.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'verificationPrivacyNotice' AND locale = 'es');

UPDATE translations
SET value = 'תמונת האימות שלך משמשת לאימות ולמניעת הונאות, נשארת פרטית, וייתכן שתישמר באופן מאובטח כדי לסייע בהגנה על הקהילה.',
    updated_at = now()
WHERE key = 'verificationPrivacyNotice' AND locale = 'he';

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'verificationPrivacyNotice', 'תמונת האימות שלך משמשת לאימות ולמניעת הונאות, נשארת פרטית, וייתכן שתישמר באופן מאובטח כדי לסייע בהגנה על הקהילה.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'verificationPrivacyNotice' AND locale = 'he');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'primaryPhotoVerificationErrorVerifiedMismatch', 'Your primary photo must match your verified identity.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorVerifiedMismatch' AND locale = 'en');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'primaryPhotoVerificationErrorVerifiedMismatch', 'Tu foto principal debe coincidir con tu identidad verificada.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorVerifiedMismatch' AND locale = 'es');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'primaryPhotoVerificationErrorVerifiedMismatch', 'התמונה הראשית שלך חייבת להתאים לזהות המאומתת שלך.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorVerifiedMismatch' AND locale = 'he');

COMMIT;
