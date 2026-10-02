BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'profileWizardPhotoPreparing', $$Preparing your photo…$$),
    ('es', 'profileWizardPhotoPreparing', $$Preparando tu foto…$$),
    ('he', 'profileWizardPhotoPreparing', $$מכין את התמונה שלך…$$),
    ('en', 'profileWizardPhotoUploading', $$Uploading and verifying your photo…$$),
    ('es', 'profileWizardPhotoUploading', $$Subiendo y verificando tu foto…$$),
    ('he', 'profileWizardPhotoUploading', $$מעלה ומאמת את התמונה שלך…$$),
    ('en', 'profileWizardCompletingProfile', $$Setting up your profile…$$),
    ('es', 'profileWizardCompletingProfile', $$Configurando tu perfil…$$),
    ('he', 'profileWizardCompletingProfile', $$מגדיר את הפרופיל שלך…$$)
)
INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), translation_values.locale, translation_values.key, translation_values.value, now(), now()
FROM translation_values
WHERE NOT EXISTS (
  SELECT 1
  FROM translations t
  WHERE t.locale = translation_values.locale
    AND t.key = translation_values.key
);

COMMIT;
