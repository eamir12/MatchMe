BEGIN;

-- Retry button for the verification capture error card (assets/web
-- verification_capture pages). Falls back to English in-app until shipped.
INSERT INTO translations (key, value, locale) VALUES
  ('verificationCaptureRetry', 'Retry', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

INSERT INTO translations (key, value, locale) VALUES
  ('verificationCaptureRetry', 'Reintentar', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

INSERT INTO translations (key, value, locale) VALUES
  ('verificationCaptureRetry', 'נסה שוב', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

COMMIT;
