INSERT INTO public.translations (key, value, locale)
VALUES
  (
    'securityCenterAuthenticatorPrimaryVerified',
    'Authenticator protection is on. Sensitive changes ask for verification when needed.',
    'en'
  ),
  (
    'securityCenterAuthenticatorPrimaryOn',
    'Authenticator protection is on. Sensitive changes ask for verification when needed.',
    'en'
  ),
  (
    'securityCenterAuthenticatorPrimaryVerified',
    'La proteccion con autenticador esta activada. Los cambios sensibles solicitaran verificacion cuando sea necesario.',
    'es'
  ),
  (
    'securityCenterAuthenticatorPrimaryOn',
    'La proteccion con autenticador esta activada. Los cambios sensibles solicitaran verificacion cuando sea necesario.',
    'es'
  ),
  (
    'securityCenterAuthenticatorPrimaryVerified',
    'ההגנה באמצעות מאמת פעילה. שינויים רגישים יבקשו אימות בעת הצורך.',
    'he'
  ),
  (
    'securityCenterAuthenticatorPrimaryOn',
    'ההגנה באמצעות מאמת פעילה. שינויים רגישים יבקשו אימות בעת הצורך.',
    'he'
  )
ON CONFLICT (key, locale) DO UPDATE
SET value = EXCLUDED.value;
