-- Add translations for mandatory height validation in profile wizard
-- Ensures all user-facing text comes from Supabase translations table (en/es/he)
-- English fallback is also in lib/providers/locale_provider.dart

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'profileEditHeightRequired', 'Height is required'),
  ('es', 'profileEditHeightRequired', 'La altura es obligatoria'),
  ('he', 'profileEditHeightRequired', 'נדרש גובה'),
  ('en', 'profileEditHeightInvalid', 'Height must be between 100 and 250 centimeters'),
  ('es', 'profileEditHeightInvalid', 'La altura debe estar entre 100 y 250 centímetros'),
  ('he', 'profileEditHeightInvalid', 'הגובה חייב להיות בין 100 ל-250 סנטימטרים'),
  ('en', 'profileEditHeightInvalidFeet', 'Height must be between 3 feet 4 inches and 8 feet 2 inches'),
  ('es', 'profileEditHeightInvalidFeet', 'La altura debe estar entre 3 pies 4 pulgadas y 8 pies 2 pulgadas'),
  ('he', 'profileEditHeightInvalidFeet', 'הגובה חייב להיות בין 3 רגל 4 אינטש ל-8 רגל 2 אינטש')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
