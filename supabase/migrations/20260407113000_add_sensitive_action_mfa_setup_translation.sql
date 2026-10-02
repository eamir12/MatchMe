INSERT INTO public.translations (key, value, locale)
VALUES
  (
    'settingsSensitiveActionRequiresMfaSetup',
    'Set up an authenticator app or a passkey before changing this security setting.',
    'en'
  ),
  (
    'settingsSensitiveActionRequiresMfaSetup',
    'Configura una aplicacion de autenticacion o una passkey antes de cambiar esta configuracion de seguridad.',
    'es'
  ),
  (
    'settingsSensitiveActionRequiresMfaSetup',
    'יש להגדיר אפליקציית מאמת או מפתח גישה לפני שינוי הגדרת האבטחה הזו.',
    'he'
  )
ON CONFLICT (key, locale) DO UPDATE
SET value = EXCLUDED.value;
