-- Migration: localize Location #N + remaining map strings (were English-only)
BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'matchLocationOccurrence', 'מיקום #{count}'),
  ('he', 'matchLocationTitle', 'מיקום ההתאמה'),
  ('he', 'matchNoLocation', 'מיקום לא זמין להתאמה זו'),
  ('he', 'matchMiniMapDescProximity', 'הייתם קרובים זה לזה כאן')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'matchLocationOccurrence', 'Ubicación n.º {count}'),
  ('es', 'matchLocationTitle', 'Ubicación de la conexión'),
  ('es', 'matchNoLocation', 'Ubicación no disponible para esta conexión'),
  ('es', 'matchMiniMapDescProximity', 'Estabais cerca el uno del otro aquí')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
