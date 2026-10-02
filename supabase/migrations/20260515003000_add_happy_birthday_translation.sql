BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'happyBirthday', 'Happy Birthday'),
  ('es', 'happyBirthday', 'Feliz Cumpleaños'),
  ('he', 'happyBirthday', 'יום הולדת שמח')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
