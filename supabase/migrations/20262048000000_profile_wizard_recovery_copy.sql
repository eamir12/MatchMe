INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileWizardErrorLoadingIntents', 'Error loading intents'),
  ('en', 'profileWizardErrorLoadingInterests', 'Error loading interests'),
  ('en', 'profileWizardReferenceDataErrorMessage', 'We couldn’t load the profile options. Try again.'),
  ('en', 'profileWizardRecoveryMessage', 'Your progress is still here. Check your connection and try again.'),
  ('es', 'profileWizardErrorLoadingIntents', 'Error al cargar intenciones'),
  ('es', 'profileWizardErrorLoadingInterests', 'Error al cargar intereses'),
  ('es', 'profileWizardReferenceDataErrorMessage', 'No pudimos cargar las opciones del perfil. Inténtalo de nuevo.'),
  ('es', 'profileWizardRecoveryMessage', 'Tu progreso sigue aquí. Comprueba tu conexión e inténtalo de nuevo.'),
  ('he', 'profileWizardErrorLoadingIntents', 'נכשרה טעינת הכיוונים'),
  ('he', 'profileWizardErrorLoadingInterests', 'נכשרה טעינת העניינים'),
  ('he', 'profileWizardReferenceDataErrorMessage', 'לא ניתן לטעון את אפשרויות הפרופיל. נסו שוב.'),
  ('he', 'profileWizardRecoveryMessage', 'ההתקדמות שלך עדיין כאן. בדקו את החיבור ונסו שוב.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
