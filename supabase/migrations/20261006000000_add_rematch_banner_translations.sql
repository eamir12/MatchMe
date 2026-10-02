-- Migration: Add localized translations for rematch banner with name
-- Ensures banner text is in Supabase translations table for en/he/es
-- and has English fallback in Dart (locale_provider.dart _defaultTranslations)
BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- English (fallback already in code, but ensure table has it)
  ('en', 'rematchBanner2', 'Rematch! This is your 2nd time matching with {name}'),
  ('en', 'rematchBanner3', 'Rematch! This is your 3rd time matching with {name}'),
  ('en', 'rematchBanner', 'Rematch! This is your {count} time matching with {name}'),
  -- Ensure old keys are also present for completeness (en already exists, use DO NOTHING)
  ('en', 'rematchIndicator', 'This is the {count} time you matched!'),
  ('en', 'rematchIndicator2', 'This is the 2nd time you matched!'),
  ('en', 'rematchIndicator3', 'This is the 3rd time you matched!')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'rematchBanner2', 'התאמה מחודשת! זו הפעם השנייה שלך עם {name}'),
  ('he', 'rematchBanner3', 'התאמה מחודשת! זו הפעם השלישית שלך עם {name}'),
  ('he', 'rematchBanner', 'התאמה מחודשת! זו הפעם ה-{count} שלך עם {name}'),
  ('he', 'rematchIndicator', 'זו הפעם ה-{count} שאתם מתאימים!'),
  ('he', 'rematchIndicator2', 'זו הפעם השנייה שאתם מתאימים!'),
  ('he', 'rematchIndicator3', 'זו הפעם השלישית שאתם מתאימים!')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'rematchBanner2', '¡Reencuentro! Esta es tu 2ª vez conectando con {name}'),
  ('es', 'rematchBanner3', '¡Reencuentro! Esta es tu 3ª vez conectando con {name}'),
  ('es', 'rematchBanner', '¡Reencuentro! Esta es tu {count}ª vez conectando con {name}'),
  ('es', 'rematchIndicator', '¡Esta es la {count}ª vez que conectáis!'),
  ('es', 'rematchIndicator2', '¡Esta es la 2ª vez que conectáis!'),
  ('es', 'rematchIndicator3', '¡Esta es la 3ª vez que conectáis!')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
