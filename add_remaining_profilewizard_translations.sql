-- Add remaining missing profile wizard translations
-- Languages: en (English), es (Spanish), he (Hebrew)

INSERT INTO translations (locale, key, value) VALUES
  -- Photo operation error messages
  ('en', 'profileWizardPhotoEditFailed', 'Failed to edit photo'),
  ('es', 'profileWizardPhotoEditFailed', 'Error al editar la foto'),
  ('he', 'profileWizardPhotoEditFailed', 'נכשרה עריכת התמונה'),

  ('en', 'profileWizardPhotoRemoveFailed', 'Failed to remove photo'),
  ('es', 'profileWizardPhotoRemoveFailed', 'Error al eliminar la foto'),
  ('he', 'profileWizardPhotoRemoveFailed', 'נכשרה הסרת התמונה'),

  -- Error loading languages
  ('en', 'profileWizardErrorLoadingLanguages', 'Error loading languages'),
  ('es', 'profileWizardErrorLoadingLanguages', 'Error al cargar los idiomas'),
  ('he', 'profileWizardErrorLoadingLanguages', 'נכשרה טעינת השפות'),

  -- Profile not found
  ('en', 'profileNotFound', 'Profile not found'),
  ('es', 'profileNotFound', 'Perfil no encontrado'),
  ('he', 'profileNotFound', 'הפרופיל לא נמצא'),

  -- Must be 18 years old
  ('en', 'profileEditMustBe18', 'You must be at least 18 years old'),
  ('es', 'profileEditMustBe18', 'Debes tener al menos 18 años'),
  ('he', 'profileEditMustBe18', 'חייב להיות מעל גיל 18')

ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();