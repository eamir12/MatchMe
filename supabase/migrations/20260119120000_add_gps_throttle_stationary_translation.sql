-- Add localized translations for GPS stationary throttling notification
-- Note: {interval} placeholder will be replaced with actual interval in seconds

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'gpsThrottledStationary', 'Not moving — GPS updates reduced to once every {interval} seconds to save battery. This will resume when you start moving.'),
  ('he', 'gpsThrottledStationary', 'לא זז — עדכוני GPS יופחתו לפעם ב־{interval} שניות כדי לשמור על סוללה. זה יחזור כשתתחיל לזוז.'),
  ('es', 'gpsThrottledStationary', 'Sin movimiento — las actualizaciones de GPS se reducen a una vez cada {interval} segundos para ahorrar batería. Se reanudará cuando empieces a moverte.')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value;

-- Note: Add additional locales as needed.
