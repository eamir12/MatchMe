-- Onboarding cleanup + settings chapter wording fix.
-- 1) Removes demo-only translation keys that turned out to be dead: the
--    replica scenes no longer reference them (pruned from the built-in
--    fallbacks in locale_provider.dart at the same time).
-- 2) Re-words onboardingBeatSettings4 in all three locales: the security
--    center and account management are separate settings rows, so the
--    narration now points at each row instead of merging them.
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run (later migration wins over earlier seeds).

DELETE FROM public.translations
WHERE key IN (
  'onboardingDemoEncrypted',
  'onboardingDemoPrivacyNote',
  'onboardingDemoAddToCalendar',
  'onboardingDemoEditProfile',
  'onboardingDemoSettingsHint'
);

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'onboardingBeatSettings4', 'Your security center lives here too… Sign in with passkeys and protect your account with an authenticator app and recovery codes. Your account row sits right below — change your email or manage your account details there.'),
  ('es', 'onboardingBeatSettings4', 'Tu centro de seguridad también vive aquí… Inicia sesión con llaves de acceso y protege tu cuenta con una app de autenticación y códigos de recuperación. La fila de tu cuenta está justo debajo — cambia tu correo o gestiona los detalles de tu cuenta allí.'),
  ('he', 'onboardingBeatSettings4', 'מרכז האבטחה שלכם נמצא גם כאן… התחברו עם מפתחות גישה והגנו על החשבון עם אפליקציית אימות וקודי שחזור. שורת החשבון שלכם נמצאת ממש למטה – שם תוכלו להחליף את כתובת הדוא״ל או לנהל את פרטי החשבון.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;