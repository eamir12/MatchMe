INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'eventLinkOpenFailed', 'Could not open the event link. Please try again.'),
  ('es', 'eventLinkOpenFailed', 'No se pudo abrir el enlace del evento. Inténtalo de nuevo.'),
  ('he', 'eventLinkOpenFailed', 'לא ניתן היה לפתוח את קישור האירוע. נסה שוב.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
