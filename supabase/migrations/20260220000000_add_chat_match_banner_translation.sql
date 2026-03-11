BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('chatMatchedWithOnDate', 'You matched with {name} on {date}', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('chatMatchedWithOnDate', 'Hiciste match con {name} el {date}', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('chatMatchedWithOnDate', 'התאמת עם {name} בתאריך {date}', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
