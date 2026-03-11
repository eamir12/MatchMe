-- Primary Photo Verification Error Translations

-- English
INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'primaryPhotoVerificationErrorSystem', 'Unable to verify your photo right now. Please try again.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorSystem' AND locale = 'en');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'primaryPhotoVerificationErrorNoPerson', 'No person found. Please show your face clearly.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorNoPerson' AND locale = 'en');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'primaryPhotoVerificationErrorFaceNotVisible', 'Face not clearly visible. Please check lighting.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorFaceNotVisible' AND locale = 'en');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'primaryPhotoVerificationErrorBadContent', 'Photo contains restricted content.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorBadContent' AND locale = 'en');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'primaryPhotoVerificationErrorGeneral', 'Please use a clear face or body photo.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorGeneral' AND locale = 'en');

-- Spanish (es)
INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'primaryPhotoVerificationErrorSystem', 'No se pudo verificar tu foto en este momento. Inténtalo de nuevo.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorSystem' AND locale = 'es');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'primaryPhotoVerificationErrorNoPerson', 'No se encontró ninguna persona. Muestra tu rostro claramente.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorNoPerson' AND locale = 'es');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'primaryPhotoVerificationErrorFaceNotVisible', 'El rostro no es claramente visible. Verifica la iluminación.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorFaceNotVisible' AND locale = 'es');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'primaryPhotoVerificationErrorBadContent', 'La foto contiene contenido restringido.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorBadContent' AND locale = 'es');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'primaryPhotoVerificationErrorGeneral', 'Por favor, usa una foto clara de tu rostro o cuerpo.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorGeneral' AND locale = 'es');

-- Hebrew (he)
INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'primaryPhotoVerificationErrorSystem', 'לא ניתן לאמת את התמונה כרגע. נא לנסות שוב.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorSystem' AND locale = 'he');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'primaryPhotoVerificationErrorNoPerson', 'לא נמצא אדם. נא להראות את הפנים בבירור.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorNoPerson' AND locale = 'he');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'primaryPhotoVerificationErrorFaceNotVisible', 'הפנים לא נראים בבירור. נא לבדוק את התאורה.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorFaceNotVisible' AND locale = 'he');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'primaryPhotoVerificationErrorBadContent', 'התמונה מכילה תוכן מוגבל.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorBadContent' AND locale = 'he');

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'primaryPhotoVerificationErrorGeneral', 'נא להשתמש בתמונה ברורה של הפנים או הגוף.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorGeneral' AND locale = 'he');
