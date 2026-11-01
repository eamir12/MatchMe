-- Add session-expired re-login prompt translations
-- Keys: sessionExpiredTitle, sessionExpiredBody, sessionExpiredSignInAgain, sessionExpiredNotNow

BEGIN;

-- English translations (must match the LocaleProvider defaults verbatim)
INSERT INTO translations (key, value, locale) VALUES
  ('sessionExpiredTitle', 'Your session has expired', 'en'),
  ('sessionExpiredBody', 'Sign in again to keep using MatchMe. Your matches, chats and photos are safe.', 'en'),
  ('sessionExpiredSignInAgain', 'Sign in again', 'en'),
  ('sessionExpiredNotNow', 'Not now', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (key, value, locale) VALUES
  ('sessionExpiredTitle', 'Tu sesión ha caducado', 'es'),
  ('sessionExpiredBody', 'Vuelve a iniciar sesión para seguir usando MatchMe. Tus matches, chats y fotos están a salvo.', 'es'),
  ('sessionExpiredSignInAgain', 'Iniciar sesión de nuevo', 'es'),
  ('sessionExpiredNotNow', 'Ahora no', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (key, value, locale) VALUES
  ('sessionExpiredTitle', 'פג תוקף ההתחברות', 'he'),
  ('sessionExpiredBody', 'כדי להמשיך להשתמש ב-MatchMe יש להתחבר מחדש. ההתאמות, הצ''אטים והתמונות שלך שמורים.', 'he'),
  ('sessionExpiredSignInAgain', 'התחברות מחדש', 'he'),
  ('sessionExpiredNotNow', 'לא עכשיו', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
