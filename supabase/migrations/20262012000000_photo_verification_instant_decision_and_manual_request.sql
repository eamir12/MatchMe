BEGIN;

-- 1. Multilingual translations for manual review request
INSERT INTO public.translations (key, value, locale) VALUES
  ('requestManualReview', 'Request Manual Review', 'en'),
  ('requestManualReviewHint', 'Think the AI got it wrong? You can request our team to review your photo manually.', 'en'),
  ('manualReviewRequestedSuccess', 'Your verification photo has been submitted for manual review.', 'en'),
  ('manualReviewRequestConfirmTitle', 'Request Human Review?', 'en'),
  ('manualReviewRequestConfirmMessage', 'Our team will manually review your photo. While under review, you won''t be able to submit new verification photos until the review is complete.', 'en'),
  ('manualReviewRequestButton', 'Submit for Review', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

INSERT INTO public.translations (key, value, locale) VALUES
  ('requestManualReview', 'Solicitar revisión manual', 'es'),
  ('requestManualReviewHint', '¿Crees que la IA se equivocó? Puedes solicitar a nuestro equipo que revise tu foto manualmente.', 'es'),
  ('manualReviewRequestedSuccess', 'Tu foto de verificación ha sido enviada para revisión manual.', 'es'),
  ('manualReviewRequestConfirmTitle', '¿Solicitar revisión humana?', 'es'),
  ('manualReviewRequestConfirmMessage', 'Nuestro equipo revisará tu foto manualmente. Mientras esté en revisión, no podrás enviar nuevas fotos de verificación hasta que se complete la revisión.', 'es'),
  ('manualReviewRequestButton', 'Enviar para revisión', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

INSERT INTO public.translations (key, value, locale) VALUES
  ('requestManualReview', 'בקש בדיקה ידנית', 'he'),
  ('requestManualReviewHint', 'חושב שה-AI טעה? תוכל לבקש מהצוות שלנו לבדוק את התמונה שלך באופן ידני.', 'he'),
  ('manualReviewRequestedSuccess', 'תמונת האימות שלך נשלחה לבדיקה ידנית.', 'he'),
  ('manualReviewRequestConfirmTitle', 'לבקש בדיקה אנושית?', 'he'),
  ('manualReviewRequestConfirmMessage', 'הצוות שלנו יבדוק את התמונה שלך ידנית. בזמן שהיא בבדיקה, לא תוכל לשלוח תמונות אימות חדשות עד לסיום הבדיקה.', 'he'),
  ('manualReviewRequestButton', 'שלח לבדיקה', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

-- 2. Security Definer RPC allowing an authenticated user with a rejected verification to escalate to manual review
CREATE OR REPLACE FUNCTION public.request_verification_manual_review()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_current_status text;
  v_photo_path text;
  v_current_ai jsonb;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT
    u.verification_status,
    u.verification_photo_path,
    COALESCE(u.verification_ai_analysis, '{}'::jsonb)
  INTO
    v_current_status,
    v_photo_path,
    v_current_ai
  FROM public.users u
  WHERE u.id = v_user_id;

  IF v_current_status IS NULL THEN
    RAISE EXCEPTION 'user not found';
  END IF;

  IF v_current_status = 'approved' THEN
    RAISE EXCEPTION 'user is already verified';
  END IF;

  IF v_current_status = 'pending' THEN
    -- Already under review, no-op
    RETURN;
  END IF;

  IF v_photo_path IS NULL OR trim(v_photo_path) = '' THEN
    RAISE EXCEPTION 'no verification photo found to review';
  END IF;

  -- Temporarily elevate role to bypass block_protected_user_fields_update trigger
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  UPDATE public.users
  SET
    verification_status = 'pending',
    verification_auto_rejected = false,
    verification_reviewed_at = NULL,
    verification_reviewer_id = NULL,
    verification_photo_retention_until = now() + interval '14 days',
    verification_ai_analysis = v_current_ai || jsonb_build_object(
      'manualReviewRequestedAt', now()::text,
      'decisionReason', 'user_requested_manual_review'
    )
  WHERE id = v_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_verification_manual_review() TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_verification_manual_review() TO service_role;

COMMIT;
