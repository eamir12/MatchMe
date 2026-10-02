INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'eventOpenInMaps', 'Open in Maps'),
  ('es', 'eventOpenInMaps', 'Abrir en Maps'),
  ('he', 'eventOpenInMaps', 'פתיחה במפות')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
