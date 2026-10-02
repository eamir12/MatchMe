-- Add missing location share translation keys
-- Keys: locationShareStarted, locationShareDurationUpdated, locationShareChangeDuration,
--        locationShareMutualActive, locationShareTapToView, locationShareWaiting

BEGIN;

-- English translations
INSERT INTO translations (key, value, locale) VALUES
  ('locationShareStarted', 'Live location sharing started', 'en'),
  ('locationShareDurationUpdated', 'Duration updated', 'en'),
  ('locationShareChangeDuration', 'Change Duration', 'en'),
  ('locationShareMutualActive', 'Mutual location sharing active', 'en'),
  ('locationShareTapToView', 'Tap to view on map', 'en'),
  ('locationShareWaiting', 'Waiting for location...', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (key, value, locale) VALUES
  ('locationShareStarted', 'Compartición de ubicación en vivo iniciada', 'es'),
  ('locationShareDurationUpdated', 'Duración actualizada', 'es'),
  ('locationShareChangeDuration', 'Cambiar duración', 'es'),
  ('locationShareMutualActive', 'Compartición mutua de ubicación activa', 'es'),
  ('locationShareTapToView', 'Toca para ver en el mapa', 'es'),
  ('locationShareWaiting', 'Esperando ubicación...', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (key, value, locale) VALUES
  ('locationShareStarted', 'שיתוף מיקום חי החל', 'he'),
  ('locationShareDurationUpdated', 'משך הזמן עודכן', 'he'),
  ('locationShareChangeDuration', 'שנה משך זמן', 'he'),
  ('locationShareMutualActive', 'שיתוף מיקום הדדי פעיל', 'he'),
  ('locationShareTapToView', 'לחץ כדי לצפות במפה', 'he'),
  ('locationShareWaiting', 'ממתין למיקום...', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
