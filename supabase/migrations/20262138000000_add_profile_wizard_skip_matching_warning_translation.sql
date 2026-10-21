-- Migration: Warn users that skipping voluntary matching fields can exclude
--   them from potential matches whose filters rely on those fields.
-- The English fallback also lives in lib/providers/locale_provider.dart.

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileWizardSkipConfirmMatchingWarning', 'Some of the fields on this page are used in match filters. If you skip them, you may be excluded from potential matches that filter on them.'),
  ('es', 'profileWizardSkipConfirmMatchingWarning', 'Algunos de los campos de esta página se usan en los filtros de coincidencias. Si los omites, es posible que quedes excluido de posibles coincidencias que filtran por ellos.'),
  ('he', 'profileWizardSkipConfirmMatchingWarning', 'חלק מהשדות בעמוד זה משמשים במסנני התאמות. אם תדלג עליהם, ייתכן שתוחרג מהתאמות פוטנציאליות שמסננות לפי שדות אלה.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
