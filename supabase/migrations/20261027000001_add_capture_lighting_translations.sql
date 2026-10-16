-- Capture-page live lighting gate translations (en/es/he)
-- Keys introduced with the low-light capture refusal: the "Good lighting"
-- checklist row and the "It's too dark here" status shown (and spoken via
-- the voice-guidance bridge) while the face-region luma gate is failing on
-- the verification capture page (FACE_ONLY primary selfie + gesture flow).
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run.

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'verificationCaptureChecklistLighting', 'Good lighting'),
  ('en', 'verificationCaptureStatusTooDark', 'It’s too dark here — move to a brighter spot')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'verificationCaptureChecklistLighting', 'Buena iluminación'),
  ('es', 'verificationCaptureStatusTooDark', 'Está muy oscuro aquí — muévete a un lugar con más luz')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations (RTL support)
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'verificationCaptureChecklistLighting', 'תאורה טובה'),
  ('he', 'verificationCaptureStatusTooDark', 'חשוך מדי כאן — עבור/י למקום מואר יותר')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
