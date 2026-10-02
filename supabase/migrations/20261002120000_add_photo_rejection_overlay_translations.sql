BEGIN;

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'photoRejectedTitle', 'Photo not approved', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoRejectedTitle' AND locale = 'en'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'photoRejectedTitle', 'Foto no aprobada', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoRejectedTitle' AND locale = 'es'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'photoRejectedTitle', 'התמונה לא אושרה', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoRejectedTitle' AND locale = 'he'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'photoIssueText', 'Text overlay', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueText' AND locale = 'en'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'photoIssueText', 'Texto superpuesto', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueText' AND locale = 'es'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'photoIssueText', 'טקסט מוטבע', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueText' AND locale = 'he'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'photoIssueWatermark', 'Watermark', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueWatermark' AND locale = 'en'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'photoIssueWatermark', 'Marca de agua', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueWatermark' AND locale = 'es'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'photoIssueWatermark', 'סימן מים', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueWatermark' AND locale = 'he'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'photoIssueScreenshot', 'Screenshot', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueScreenshot' AND locale = 'en'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'photoIssueScreenshot', 'Captura de pantalla', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueScreenshot' AND locale = 'es'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'photoIssueScreenshot', 'צילום מסך', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueScreenshot' AND locale = 'he'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'photoIssueMeme', 'Meme', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueMeme' AND locale = 'en'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'photoIssueMeme', 'Meme', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueMeme' AND locale = 'es'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'photoIssueMeme', 'מימ', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueMeme' AND locale = 'he'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'photoIssueFace', 'Face', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueFace' AND locale = 'en'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'photoIssueFace', 'Rostro', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueFace' AND locale = 'es'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'photoIssueFace', 'פנים', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'photoIssueFace' AND locale = 'he'
);

COMMIT;
