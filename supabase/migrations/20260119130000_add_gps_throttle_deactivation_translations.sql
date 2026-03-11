-- Add localized translations for GPS throttling deactivation notifications
-- These are temporary notifications that auto-dismiss after a few seconds

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'gpsThrottleDeactivatedBattery', 'Battery restored — GPS updates returned to normal interval.'),
  ('he', 'gpsThrottleDeactivatedBattery', 'הסוללה שוחזרה — עדכוני GPS חזרו למרווח רגיל.'),
  ('es', 'gpsThrottleDeactivatedBattery', 'Batería restaurada — las actualizaciones de GPS volvieron al intervalo normal.'),
  ('en', 'gpsThrottleDeactivatedMoving', 'Movement detected — GPS updates returned to normal interval.'),
  ('he', 'gpsThrottleDeactivatedMoving', 'זוהתה תנועה — עדכוני GPS חזרו למרווח רגיל.'),
  ('es', 'gpsThrottleDeactivatedMoving', 'Movimiento detectado — las actualizaciones de GPS volvieron al intervalo normal.')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value;

-- Note: Add additional locales as needed.
