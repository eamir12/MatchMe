-- Add translations for required/optional field labeling and the
-- skip-confirmation dialog in the profile wizard (en/es/he)
-- English fallback is also in lib/providers/locale_provider.dart

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'profileFieldOptional', 'optional'),
  ('es', 'profileFieldOptional', 'opcional'),
  ('he', 'profileFieldOptional', 'לא חובה'),
  ('en', 'profileWizardRequiredLegend', 'Fields marked * are required and must be filled in to continue.'),
  ('es', 'profileWizardRequiredLegend', 'Los campos marcados con * son obligatorios y deben completarse para continuar.'),
  ('he', 'profileWizardRequiredLegend', 'השדות המסומנים ב-* הם שדות חובה שיש למלא כדי להמשיך.'),
  ('en', 'profileWizardAllOptionalHint', 'Everything on this page is optional — you can skip it now and complete it later.'),
  ('es', 'profileWizardAllOptionalHint', 'Todo en esta página es opcional; puedes omitirlo ahora y completarlo más tarde.'),
  ('he', 'profileWizardAllOptionalHint', 'הכול בעמוד זה הוא לא חובה — ניתן לדלג עליו כעת ולהשלים אותו מאוחר יותר.'),
  ('en', 'profileWizardSkipConfirmTitle', 'Skip this step?'),
  ('es', 'profileWizardSkipConfirmTitle', '¿Omitir este paso?'),
  ('he', 'profileWizardSkipConfirmTitle', 'לדלג על שלב זה?'),
  ('en', 'profileWizardSkipConfirmBody', 'You haven''t filled in anything on this page. All of it is optional — you can complete it later in your profile. Would you like to skip it for now?'),
  ('es', 'profileWizardSkipConfirmBody', 'No has completado nada en esta página. Todo es opcional; puedes completarlo más tarde en tu perfil. ¿Quieres omitirlo por ahora?'),
  ('he', 'profileWizardSkipConfirmBody', 'לא מילאת דבר בעמוד זה. הכול כאן הוא לא חובה — תוכל להשלים זאת מאוחר יותר בפרופיל שלך. לדלג על זה כעת?'),
  ('en', 'profileWizardSkipConfirmMatchingWarning', 'Some of the fields on this page are used in match filters. If you skip them, you may be excluded from potential matches that filter on them.'),
  ('es', 'profileWizardSkipConfirmMatchingWarning', 'Algunos de los campos de esta página se usan en los filtros de coincidencias. Si los omites, es posible que quedes excluido de posibles coincidencias que filtran por ellos.'),
  ('he', 'profileWizardSkipConfirmMatchingWarning', 'חלק מהשדות בעמוד זה משמשים במסנני התאמות. אם תדלג עליהם, ייתכן שתוחרג מהתאמות פוטנציאליות שמסננות לפי שדות אלה.'),
  ('en', 'profileWizardSkipConfirmFillNow', 'Fill in now'),
  ('es', 'profileWizardSkipConfirmFillNow', 'Completar ahora'),
  ('he', 'profileWizardSkipConfirmFillNow', 'למלא כעת'),
  ('en', 'profileWizardSkipConfirmSkip', 'Skip for now'),
  ('es', 'profileWizardSkipConfirmSkip', 'Omitir por ahora'),
  ('he', 'profileWizardSkipConfirmSkip', 'לדלג לעת עתה'),
  ('en', 'profileWizardPhotosRequiredNote', 'At least one photo is required to continue.'),
  ('es', 'profileWizardPhotosRequiredNote', 'Se necesita al menos una foto para continuar.'),
  ('he', 'profileWizardPhotosRequiredNote', 'נדרשת לפחות תמונה אחת כדי להמשיך.'),
  ('en', 'profileEditMustBe18', 'You must be at least 18 years old to use MatchMe.'),
  ('es', 'profileEditMustBe18', 'Debes tener al menos 18 años para usar MatchMe.'),
  ('he', 'profileEditMustBe18', 'עליך להיות בן 18 לפחות כדי להשתמש ב-MatchMe.')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
