-- OAuth provider unavailable translations (en/es/he)
-- Keys introduced to surface a friendly message when Apple/Facebook OAuth
-- buttons are tapped while those providers are disabled in the app build.
-- The buttons are rendered greyed out; tapping them sets _errorMessageKey
-- to authOAuthProviderUnavailable so the localized message appears in the
-- auth error banner instead of starting an OAuth flow.
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run.

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'authOAuthProviderUnavailable',
   'This sign-in method is currently unavailable. Please use another option.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'authOAuthProviderUnavailable',
   'Este método de inicio de sesión no está disponible actualmente. Por favor, usa otra opción.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations (RTL support)
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'authOAuthProviderUnavailable',
   'שיטת הכניסה הזו אינה זמינה כרגע. נא להשתמש באפשרות אחרת.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
