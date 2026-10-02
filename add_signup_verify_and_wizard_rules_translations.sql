-- Translations for sign-up verify password + profile wizard rules
-- (height optional for Romantic, occupation/education mandatory for Business, languages optional)
-- Ensures all user-facing text comes from Supabase translations table (en/es/he)
-- English fallback is also in lib/providers/locale_provider.dart

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'authConfirmPassword', 'Confirm password'),
  ('es', 'authConfirmPassword', 'Confirmar contraseña'),
  ('he', 'authConfirmPassword', 'אישור סיסמה'),
  ('en', 'authConfirmPasswordRequired', 'Password confirmation is required'),
  ('es', 'authConfirmPasswordRequired', 'La confirmación de la contraseña es obligatoria'),
  ('he', 'authConfirmPasswordRequired', 'נדרש אישור סיסמה'),
  ('en', 'authPasswordsDoNotMatch', 'Passwords do not match'),
  ('es', 'authPasswordsDoNotMatch', 'Las contraseñas no coinciden'),
  ('he', 'authPasswordsDoNotMatch', 'הסיסמאות אינן תואמות'),
  ('en', 'profileWizardHeightOptionalNote', 'Height is optional. If you skip it, you will only match with people who did not set any height restriction.'),
  ('es', 'profileWizardHeightOptionalNote', 'La altura es opcional. Si la omites, solo coincidirás con personas que no hayan establecido ninguna restricción de altura.'),
  ('he', 'profileWizardHeightOptionalNote', 'הגובה הוא אופציונלי. אם תדלג עליו, תתאים רק לאנשים שלא הגדירו שום הגבלת גובה.'),
  ('en', 'profileEditOccupationRequired', 'Occupation is required for business networking profiles'),
  ('es', 'profileEditOccupationRequired', 'La ocupación es obligatoria para perfiles de negocios y networking'),
  ('he', 'profileEditOccupationRequired', 'נדרשת תעסוקה עבור פרופילים עסקיים'),
  ('en', 'profileEditEducationRequired', 'Education is required for business networking profiles'),
  ('es', 'profileEditEducationRequired', 'La educación es obligatoria para perfiles de negocios y networking'),
  ('he', 'profileEditEducationRequired', 'נדרשת השכלה עבור פרופילים עסקיים')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
