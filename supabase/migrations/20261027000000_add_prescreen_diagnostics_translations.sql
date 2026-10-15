-- Photo prescreen diagnostics translations (en/es/he)
-- Keys introduced with the prescreen false-positive hardening: the overlay
-- caption explaining what the orange outlines mean, and the collapsed
-- "Technical details" rows (measured brightness/confidence/tilt vs the
-- threshold, analyzer build) in the prescreen failure dialog.
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run.

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'photoPrescreenOverlayCaption', 'Outlined region: highlighted by the checker. Large outline: your face.'),
  ('en', 'photoPrescreenDetailsLabel', 'Technical details'),
  ('en', 'photoPrescreenDetailBrightness', 'Brightness'),
  ('en', 'photoPrescreenDetailSharpness', 'Sharpness'),
  ('en', 'photoPrescreenDetailFaceConfidence', 'Face detection'),
  ('en', 'photoPrescreenDetailHeadTilt', 'Head tilt'),
  ('en', 'photoPrescreenDetailMinimum', 'min'),
  ('en', 'photoPrescreenDetailAnalyzer', 'Analyzer')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'photoPrescreenOverlayCaption', 'Región con contorno: marcada por el verificador. Contorno grande: tu rostro.'),
  ('es', 'photoPrescreenDetailsLabel', 'Detalles técnicos'),
  ('es', 'photoPrescreenDetailBrightness', 'Brillo'),
  ('es', 'photoPrescreenDetailSharpness', 'Nitidez'),
  ('es', 'photoPrescreenDetailFaceConfidence', 'Detección de rostro'),
  ('es', 'photoPrescreenDetailHeadTilt', 'Inclinación de la cabeza'),
  ('es', 'photoPrescreenDetailMinimum', 'mín'),
  ('es', 'photoPrescreenDetailAnalyzer', 'Analizador')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations (RTL support)
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'photoPrescreenOverlayCaption', 'אזור עם קו מתאר: סומן על ידי הבדיקה. קו מתאר גדול: הפנים שלך.'),
  ('he', 'photoPrescreenDetailsLabel', 'פרטים טכניים'),
  ('he', 'photoPrescreenDetailBrightness', 'בהירות'),
  ('he', 'photoPrescreenDetailSharpness', 'חדות'),
  ('he', 'photoPrescreenDetailFaceConfidence', 'זיהוי פנים'),
  ('he', 'photoPrescreenDetailHeadTilt', 'נטיית הראש'),
  ('he', 'photoPrescreenDetailMinimum', 'מינימום'),
  ('he', 'photoPrescreenDetailAnalyzer', 'מנתח')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
