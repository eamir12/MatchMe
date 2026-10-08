-- Photo prescreen on-device text detection translations (en/es/he)
-- The prescreen now runs ML Kit (Android) / Apple Vision (iOS) text
-- recognition before upload; a substantial text block (card, sign,
-- watermark, screenshot) is rejected locally with this message.
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run.

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'photoErrorTextDetected', 'Please retake the photo without any cards, signs, or visible text.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'photoErrorTextDetected', 'Vuelve a tomar la foto sin tarjetas, letreros ni texto visible.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations (RTL support)
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'photoErrorTextDetected', 'נא לצלם את התמונה מחדש ללא כרטיסים, שלטים או טקסט גלוי.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
