-- Add location share bottom-bar status button translations
-- Keys: locationShareButtonMutualActive, locationShareButtonSharing

BEGIN;

-- English translations
INSERT INTO translations (key, value, locale) VALUES
  ('locationShareButtonMutualActive', 'Mutual Sharing Active', 'en'),
  ('locationShareButtonSharing', 'Sharing Location', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (key, value, locale) VALUES
  ('locationShareButtonMutualActive', 'Intercambio mutuo activo', 'es'),
  ('locationShareButtonSharing', 'Compartiendo ubicación', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (key, value, locale) VALUES
  ('locationShareButtonMutualActive', 'שיתוף הדדי פעיל', 'he'),
  ('locationShareButtonSharing', 'שיתוף מיקום', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
