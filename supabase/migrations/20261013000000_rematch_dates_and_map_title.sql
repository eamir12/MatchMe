-- Migration: rematch multi-date labels + Where and when title
BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'matchMiniMapTitle', 'Where and when you matched'),
  ('en', 'matchFirstMatchedOn', 'First matched on:'),
  ('en', 'matchSecondMatchedOn', 'Second matched on:'),
  ('en', 'matchThirdMatchedOn', 'Third matched on:')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'matchMiniMapTitle', 'איפה ומתי התאמתם'),
  ('he', 'matchFirstMatchedOn', 'התאמה ראשונה ב:'),
  ('he', 'matchSecondMatchedOn', 'התאמה שנייה ב:'),
  ('he', 'matchThirdMatchedOn', 'התאמה שלישית ב:')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'matchMiniMapTitle', 'Dónde y cuándo conectasteis'),
  ('es', 'matchFirstMatchedOn', 'Primera conexión el:'),
  ('es', 'matchSecondMatchedOn', 'Segunda conexión el:'),
  ('es', 'matchThirdMatchedOn', 'Tercera conexión el:')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
