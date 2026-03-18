BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncApplePublicHelpLinkLabel', 'How to get my Apple public calendar link', 'en'),
  ('calendarSyncApplePublicHelpLinkOpenFailed', 'Unable to open Apple help page right now.', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncApplePublicHelpLinkLabel', 'Cómo obtener el enlace público de mi calendario de Apple', 'es'),
  ('calendarSyncApplePublicHelpLinkOpenFailed', 'No se puede abrir la página de ayuda de Apple en este momento.', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncApplePublicHelpLinkLabel', 'איך לקבל את הקישור הציבורי ליומן Apple שלי', 'he'),
  ('calendarSyncApplePublicHelpLinkOpenFailed', 'לא ניתן לפתוח את עמוד העזרה של Apple כרגע.', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
