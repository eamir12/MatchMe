-- Primary-photo replace-flow translations (en/es/he)
-- Keys introduced with the replace-primary-photo flow: the rejection
-- dialog's "Try again" action and the reassurance that the previous primary
-- photo was kept when a replacement is abandoned or rejected. The sheet's
-- gallery/camera actions reuse the existing profileWizardAddPhotoFrom*
-- keys.
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run.

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'photoRejectedTryAgain', 'Try again'),
  ('en', 'photoRejectedPrimaryKept', 'Your current primary photo was kept.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'photoRejectedTryAgain', 'Intentar de nuevo'),
  ('es', 'photoRejectedPrimaryKept', 'Tu foto principal actual se ha conservado.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations (RTL support)
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'photoRejectedTryAgain', 'נסה שוב'),
  ('he', 'photoRejectedPrimaryKept', 'התמונה הראשית הנוכחית שלך נשמרה.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
