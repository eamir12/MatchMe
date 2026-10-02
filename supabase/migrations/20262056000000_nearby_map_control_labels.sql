INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'mapZoomIn', 'Zoom in'),
  ('en', 'mapZoomOut', 'Zoom out'),
  ('es', 'mapZoomIn', 'Acercar mapa'),
  ('es', 'mapZoomOut', 'Alejar mapa'),
  ('he', 'mapZoomIn', 'התקרב למפה'),
  ('he', 'mapZoomOut', 'התרחק מהמפה')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
