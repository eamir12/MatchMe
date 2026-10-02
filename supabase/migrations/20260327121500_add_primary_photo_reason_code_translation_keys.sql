BEGIN;

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'primaryPhotoVerificationErrorMultipleFaces', 'Please use a photo with only you in it.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'primaryPhotoVerificationErrorMultipleFaces' AND locale = 'en'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'primaryPhotoVerificationErrorMultipleFaces', 'Usa una foto en la que solo salgas tú.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'primaryPhotoVerificationErrorMultipleFaces' AND locale = 'es'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'primaryPhotoVerificationErrorMultipleFaces', 'יש להשתמש בתמונה שבה רק את/ה מופיע/ה.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'primaryPhotoVerificationErrorMultipleFaces' AND locale = 'he'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'primaryPhotoVerificationErrorBodyNotAllowed', 'Please use a clear face photo.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'primaryPhotoVerificationErrorBodyNotAllowed' AND locale = 'en'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'primaryPhotoVerificationErrorBodyNotAllowed', 'Usa una foto clara de tu rostro.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'primaryPhotoVerificationErrorBodyNotAllowed' AND locale = 'es'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'primaryPhotoVerificationErrorBodyNotAllowed', 'יש להשתמש בתמונת פנים ברורה.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'primaryPhotoVerificationErrorBodyNotAllowed' AND locale = 'he'
);

COMMIT;
