-- sql/seed_translations_chat_translate_auto_disabled.sql
-- Adds a default English translation for the "chatTranslateAutoDisabled" key

INSERT INTO translations (locale, key, value)
VALUES
  ('en', 'chatTranslateAutoDisabled', 'Translations turned off (UI matches translation language)')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
