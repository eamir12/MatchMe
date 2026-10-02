-- Add interest search translations for Profile Wizard
-- Languages: en (English), es (Spanish), he (Hebrew)

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'profileWizardSearchInterestsHint', 'Search interests and sub-interests...'),
  ('es', 'profileWizardSearchInterestsHint', 'Buscar intereses y subintereses...'),
  ('he', 'profileWizardSearchInterestsHint', 'חיפוש תחומי עניין ותת-תחומי עניין...'),

  ('en', 'profileWizardSearchNoResults', 'No interests match your search'),
  ('es', 'profileWizardSearchNoResults', 'Ningún interés coincide con tu búsqueda'),
  ('he', 'profileWizardSearchNoResults', 'לא נמצאו תחומי עניין התואמים את החיפוש')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
