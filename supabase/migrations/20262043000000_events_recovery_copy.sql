INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'eventLoadErrorTitle', 'We couldn’t load your events'),
  ('en', 'eventLoadErrorMessage', 'Check your connection and try again.'),
  ('en', 'eventMoreActions', 'More actions'),
  ('es', 'eventLoadErrorTitle', 'No pudimos cargar tus eventos'),
  ('es', 'eventLoadErrorMessage', 'Comprueba tu conexión e inténtalo de nuevo.'),
  ('es', 'eventMoreActions', 'Más acciones'),
  ('he', 'eventLoadErrorTitle', 'לא ניתן לטעון את האירועים שלך'),
  ('he', 'eventLoadErrorMessage', 'בדקו את החיבור ונסו שוב.'),
  ('he', 'eventMoreActions', 'פעולות נוספות')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
