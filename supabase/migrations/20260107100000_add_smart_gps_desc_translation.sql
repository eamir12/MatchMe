-- Add localized translations for Smart GPS description

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'settingsSmartGpsThrottlingDesc', 'When enabled, Smart GPS reduces GPS updates when you are stationary, and reduces updates to once every 60 seconds when your battery is 15% or lower until charging.'),
  ('he', 'settingsSmartGpsThrottlingDesc', 'כאשר מופעל, ה־GPS החכם מפחית את תדירות העדכונים כאשר אתה עומד במקום, ומפחית אותם לפעם ב־60 שניות כאשר הסוללה נמוכה מ־15% עד שיתחבר המכשיר.'),
  ('es', 'settingsSmartGpsThrottlingDesc', 'Cuando está activado, Smart GPS reduce las actualizaciones del GPS cuando estás inmóvil y las reduce a una vez cada 60 segundos cuando la batería está al 15% o menos hasta que se cargue.');

-- Note: Add additional locales as needed.