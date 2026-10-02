INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileWizardGenderPreferenceRequired', 'Please select at least one preferred gender for {intent}.'),
  ('es', 'profileWizardGenderPreferenceRequired', 'Selecciona al menos un género preferido para {intent}.'),
  ('he', 'profileWizardGenderPreferenceRequired', 'בחר לפחות מגדם מועדף עבור {intent}.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
