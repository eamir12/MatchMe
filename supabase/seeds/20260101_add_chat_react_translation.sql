-- Add seed for chat reaction translation key
INSERT INTO translations (translation_key, lang, value)
VALUES
  ('chatReact', 'en', 'React')
ON CONFLICT (translation_key, lang) DO UPDATE SET value = EXCLUDED.value;
