INSERT INTO public.translations (key, value, locale)
VALUES
  (
    'securityCenterPasskeySessionReady',
    'A passkey is ready for future sign-ins.',
    'en'
  ),
  (
    'securityCenterPasskeySessionReady',
    'Una clave de acceso esta lista para futuros inicios de sesion.',
    'es'
  ),
  (
    'securityCenterPasskeySessionReady',
    'מפתח גישה מוכן להתחברויות עתידיות.',
    'he'
  )
ON CONFLICT (key, locale) DO UPDATE
SET value = EXCLUDED.value;
