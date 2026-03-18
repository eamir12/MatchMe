BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('eventsImportGoogle', 'Import Google Events', 'en'),
  ('eventsImportOutlook', 'Import Outlook Events', 'en'),
  ('eventsImportApple', 'Import Apple Events', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('eventsImportGoogle', 'Importar eventos de Google', 'es'),
  ('eventsImportOutlook', 'Importar eventos de Outlook', 'es'),
  ('eventsImportApple', 'Importar eventos de Apple', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('eventsImportGoogle', 'ייבוא אירועי Google', 'he'),
  ('eventsImportOutlook', 'ייבוא אירועי Outlook', 'he'),
  ('eventsImportApple', 'ייבוא אירועי Apple', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
