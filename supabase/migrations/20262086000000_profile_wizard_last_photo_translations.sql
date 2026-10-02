-- Migration: Translations for profileWizardLastPhotoRequired — the message
-- shown when a user with a completed profile tries to remove their last
-- remaining photo in the profile wizard. Enforced in the wizard UI and
-- backstopped in the provider (removePhotoAtDraft / removePhotoAt).
--
-- English rows are included so copy can be changed server-side without a
-- release. The en value matches _defaultTranslations
-- (lib/providers/locale_provider.dart).

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileWizardLastPhotoRequired', 'Your profile must keep at least one photo. Add a new photo before removing this one.'),
  ('es', 'profileWizardLastPhotoRequired', 'Tu perfil debe mantener al menos una foto. Agrega una nueva foto antes de eliminar esta.'),
  ('he', 'profileWizardLastPhotoRequired', 'הפרופיל שלך חייב לכלול לפחות תמונה אחת. הוסף תמונה חדשה לפני שתסיר את התמונה הזו.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
