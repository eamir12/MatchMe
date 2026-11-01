
-- 2026-10-23: dead-session re-login prompt keys (added with the
-- session-expired detection UX; English defaults from code).
INSERT INTO public.translations (locale, key, value)
VALUES
  ('en', 'sessionExpiredTitle', 'Your session has expired'),
  ('en', 'sessionExpiredBody', 'Sign in again to keep using MatchMe. Your matches, chats and photos are safe.'),
  ('en', 'sessionExpiredSignInAgain', 'Sign in again'),
  ('en', 'sessionExpiredNotNow', 'Not now')
ON CONFLICT (locale, key) DO NOTHING;
