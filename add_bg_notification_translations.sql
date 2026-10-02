-- Update Supabase translations for the persistent "MatchMe Active" foreground notification.
-- Ensures the title / text are localized to the user's UI language (locale) with English fallback in code.
-- Supported locales: en, es, he (see locale_provider.dart _defaultSupportedLanguages).
-- Run this once in the Supabase SQL editor. Idempotent via ON CONFLICT.

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'bgNotificationTitle', 'MatchMe Active'),
  ('en', 'bgNotificationText', 'You are visible and background matching is enabled.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES
  ('es', 'bgNotificationTitle', 'MatchMe Activo'),
  ('es', 'bgNotificationText', 'Estás visible y el emparejamiento en segundo plano está activado.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES
  ('he', 'bgNotificationTitle', 'MatchMe פעיל'),
  ('he', 'bgNotificationText', 'את/ה גלוי/ה והתאמה ברקע מופעלת.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Verify:
-- SELECT locale, key, value FROM translations WHERE key IN ('bgNotificationTitle','bgNotificationText') ORDER BY locale, key;
