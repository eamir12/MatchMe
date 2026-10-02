-- Onboarding tour fifth feedback round.
--  * The settings chapter covers the whole screen now, so its title is just
--    "Settings" (matching the real screen title) instead of "Matching
--    settings", which mismatched beats like Profile Verification.
--  * The Account beat now describes the real screen: change password or
--    email, or delete the account, with sensitive actions verified first.
--  * The nearby total count is back: five dots, five online in the pill.
-- English values intentionally match the built-in fallbacks in
-- locale_provider.dart (later migration wins over earlier seeds).
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run (ON CONFLICT DO UPDATE).

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'onboardingChapterSettings', 'Settings'),
  ('en', 'onboardingBeatSettingsAccount', 'Under Account, you change your password or email… or delete your account entirely. Sensitive actions first confirm it is really you.'),
  ('en', 'onboardingBeatNearby1', 'This map shows your match radius circle… Each dot is one online and visible member inside it — the blue marker is you. The pill up top shows all five online right now… Nobody sees your exact location… others only see an approximate distance, and only when you are visible.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'onboardingChapterSettings', 'Settings'),
  ('es', 'onboardingBeatSettingsAccount', 'En la cuenta, cambias tu contraseña o tu correo… o eliminas tu cuenta por completo. Las acciones sensibles primero confirman que eres tú.'),
  ('es', 'onboardingBeatNearby1', 'Este mapa muestra tu círculo de radio… Cada punto es un miembro en línea y visible dentro de él; el marcador azul eres tú. La píldora de arriba muestra a los cinco en línea ahora mismo… Nadie ve tu ubicación exacta… los demás solo ven una distancia aproximada, y solo cuando eres visible.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'onboardingChapterSettings', 'Settings'),
  ('he', 'onboardingBeatSettingsAccount', 'תחת חשבון תוכלו להחליף סיסמה או דוא״ל… או למחוק את החשבון לגמרי. פעולות רגישות קודם מוודאות שזה באמת אתם.'),
  ('he', 'onboardingBeatNearby1', 'המפה הזו מראה את מעגל הרדיוס שלכם… כל נקודה היא חבר מקוון וגלוי בתוכו; הסמן הכחול זה אתם. הבועה למעלה מראה שחמשתם מקוונים כרגע… אף אחד לא רואה את המיקום המדויק שלכם… האחרים רואים רק מרחק משוער, ורק כשאתם גלויים.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
