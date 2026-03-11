BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Admins can view all profile photos'
  ) THEN
    CREATE POLICY "Admins can view all profile photos"
    ON storage.objects
    FOR SELECT
    TO authenticated
    USING (
      bucket_id = 'profile-photos'
      AND EXISTS (
        SELECT 1
        FROM public.users u
        WHERE u.id = auth.uid()
          AND u.is_admin = true
      )
    );
  END IF;
END$$;

DROP FUNCTION IF EXISTS public.admin_list_verification_users(text, text, integer, integer);

CREATE OR REPLACE FUNCTION public.admin_list_verification_users(
  p_status text DEFAULT NULL,
  p_query text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  name text,
  verification_status text,
  is_verified boolean,
  profile_photo_path text,
  verification_photo_path text,
  verification_submitted_at timestamptz,
  verification_reviewed_at timestamptz,
  verification_reviewer_id uuid,
  verification_similarity_score numeric,
  verification_ai_analysis jsonb,
  verification_auto_rejected boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_status text;
  v_query text;
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
  v_query := NULLIF(trim(p_query), '');

  RETURN QUERY
  SELECT
    u.id,
    u.name,
    u.verification_status,
    u.is_verified,
    u.photos[1] AS profile_photo_path,
    u.verification_photo_path,
    u.verification_submitted_at,
    u.verification_reviewed_at,
    u.verification_reviewer_id,
    u.verification_similarity_score,
    u.verification_ai_analysis,
    u.verification_auto_rejected
  FROM public.users u
  WHERE (v_status IS NULL OR u.verification_status = v_status)
    AND (
      v_query IS NULL OR
      u.id::text ILIKE '%' || v_query || '%' OR
      COALESCE(u.name, '') ILIKE '%' || v_query || '%' OR
      COALESCE(u.verification_status, '') ILIKE '%' || v_query || '%'
    )
  ORDER BY u.verification_submitted_at DESC NULLS LAST, u.id DESC
  LIMIT GREATEST(LEAST(COALESCE(p_limit, 100), 500), 1)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_list_verification_users(text, text, integer, integer) TO authenticated;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminVerificationReviewTitle', $$Verification review$$),
  ('es', 'adminVerificationReviewTitle', $$Revisión de verificación$$),
  ('he', 'adminVerificationReviewTitle', $$סקירת אימות$$),

  ('en', 'adminVerificationProfilePhoto', $$Profile photo$$),
  ('es', 'adminVerificationProfilePhoto', $$Foto de perfil$$),
  ('he', 'adminVerificationProfilePhoto', $$תמונת פרופיל$$),

  ('en', 'adminVerificationAiAnalysis', $$AI analysis$$),
  ('es', 'adminVerificationAiAnalysis', $$Análisis de IA$$),
  ('he', 'adminVerificationAiAnalysis', $$ניתוח בינה מלאכותית$$),

  ('en', 'adminVerificationNoProfilePhoto', $$No profile photo.$$),
  ('es', 'adminVerificationNoProfilePhoto', $$No hay foto de perfil.$$),
  ('he', 'adminVerificationNoProfilePhoto', $$אין תמונת פרופיל.$$),

  ('en', 'adminVerificationNoAnalysis', $$No AI analysis available.$$),
  ('es', 'adminVerificationNoAnalysis', $$No hay análisis de IA disponible.$$),
  ('he', 'adminVerificationNoAnalysis', $$אין ניתוח בינה מלאכותית זמין.$$)
ON CONFLICT (locale, key) DO UPDATE
SET value = EXCLUDED.value;

COMMIT;
