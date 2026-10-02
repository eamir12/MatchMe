INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'secondaryPhotoVerificationErrorTextScreenshotOrWatermark', 'Please use a real photo without screenshots, prominent text, memes, or watermarks.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorTextScreenshotOrWatermark' AND locale = 'en'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'es', 'secondaryPhotoVerificationErrorTextScreenshotOrWatermark', 'Usa una foto real sin capturas de pantalla, texto destacado, memes ni marcas de agua.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorTextScreenshotOrWatermark' AND locale = 'es'
);

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'he', 'secondaryPhotoVerificationErrorTextScreenshotOrWatermark', 'יש להשתמש בתמונה אמיתית ללא צילומי מסך, טקסט בולט, ממים או סימני מים.', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM translations
  WHERE key = 'secondaryPhotoVerificationErrorTextScreenshotOrWatermark' AND locale = 'he'
);
