-- Add localized translations for GPS low-battery throttling notification
-- Note: {interval} placeholder will be replaced with actual interval in seconds
-- Note: {threshold} placeholder will be replaced with actual battery threshold percentage

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'gpsThrottledLowBattery', 'Low battery — GPS updates reduced to once every {interval} seconds to save battery. This will resume when your device is charging or battery is above {threshold}%.'),
  ('he', 'gpsThrottledLowBattery', 'סוללה נמוכה — עדכוני GPS יופחתו לפעם ב־{interval} שניות כדי לשמור על סוללה. זה יחזור כשהמכשיר יוחבר או שהסוללה תעלה מעל {threshold}%.'),
  ('es', 'gpsThrottledLowBattery', 'Batería baja — las actualizaciones de GPS se reducen a una vez cada {interval} segundos para ahorrar batería. Se reanudará cuando el dispositivo esté cargando o la batería supere el {threshold}%.')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value;

-- Note: Add additional locales as needed.