BEGIN;

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'secondaryPhotoVerificationErrorSystem', 'Unable to verify this photo right now. Please try again.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorSystem' AND locale = 'en'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'secondaryPhotoVerificationErrorSystem', 'No se puede verificar esta foto en este momento. Inténtalo de nuevo.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorSystem' AND locale = 'es'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'secondaryPhotoVerificationErrorSystem', 'לא ניתן לאמת את התמונה הזו כרגע. יש לנסות שוב.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorSystem' AND locale = 'he'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'secondaryPhotoVerificationErrorNoFaceOrBody', 'Please use a photo that clearly shows at least a face or a body.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorNoFaceOrBody' AND locale = 'en'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'secondaryPhotoVerificationErrorNoFaceOrBody', 'Usa una foto que muestre claramente al menos un rostro o un cuerpo.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorNoFaceOrBody' AND locale = 'es'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'secondaryPhotoVerificationErrorNoFaceOrBody', 'יש להשתמש בתמונה שמציגה בבירור לפחות פנים או גוף.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorNoFaceOrBody' AND locale = 'he'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'secondaryPhotoVerificationErrorBadContent', 'Photo contains restricted content.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorBadContent' AND locale = 'en'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'secondaryPhotoVerificationErrorBadContent', 'La foto contiene contenido restringido.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorBadContent' AND locale = 'es'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'secondaryPhotoVerificationErrorBadContent', 'התמונה מכילה תוכן מוגבל.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorBadContent' AND locale = 'he'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'secondaryPhotoVerificationErrorGeneral', 'Please use a clear photo of a real person.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorGeneral' AND locale = 'en'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'secondaryPhotoVerificationErrorGeneral', 'Usa una foto clara de una persona real.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorGeneral' AND locale = 'es'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'secondaryPhotoVerificationErrorGeneral', 'יש להשתמש בתמונה ברורה של אדם אמיתי.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorGeneral' AND locale = 'he'
);

COMMIT;
