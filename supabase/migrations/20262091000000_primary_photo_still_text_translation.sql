-- Primary Photo Verification Error: sanitize loop-guard translation.
-- When the app's auto-sanitize pass (crop to face + pixelate text) runs once
-- and the validator STILL flags text, tell the user to retake the photo —
-- the old message reused the BAD_CONTENT key ("Photo contains restricted
-- content"), which misdescribes the situation.

-- English
INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'primaryPhotoVerificationErrorStillText', 'We couldn''t remove the text from this photo automatically. Please retake it without any cards or text.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorStillText' AND locale = 'en');

-- Spanish (es)
INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'primaryPhotoVerificationErrorStillText', 'No pudimos eliminar el texto de esta foto automáticamente. Toma una nueva foto sin tarjetas ni texto.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorStillText' AND locale = 'es');

-- Hebrew (he)
INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'primaryPhotoVerificationErrorStillText', 'לא הצלחנו להסיר את הטקסט מהתמונה באופן אוטומטי. נא לצלם תמונה חדשה ללא כרטיסים או טקסט.', now(), now()
WHERE NOT EXISTS (SELECT 1 FROM translations WHERE key = 'primaryPhotoVerificationErrorStillText' AND locale = 'he');
