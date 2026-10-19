-- Security Center: truthful passkey copy across platforms.
--
-- The passkey card used to claim "This device does not support passkeys" and
-- "This device and server are ready for a new passkey" because the app-side
-- ceremony gate (iOS needs an associated domain) was conflated with device
-- capability. The screen now separates the two: the device metric reflects
-- real hardware capability, the copy is platform-neutral, and the Server tile
-- is gone (server configuration is not something the user can act on).
--
-- Also renames the authenticator card to "Two-factor authentication" so it no
-- longer implies an authenticator app is installed on the current device.

INSERT INTO public.translations (locale, key, value) VALUES
-- Two-factor authentication card title
('en', 'settingsMfaTitle', 'Two-factor authentication'),
('es', 'settingsMfaTitle', 'Autenticación de dos factores'),
('he', 'settingsMfaTitle', 'אימות דו-גורמי'),

-- Ready-state directive: tell the user what to do on this device
('en', 'securityCenterPasskeySecondaryReady', 'Create a passkey on this device to sign in without a password.'),
('es', 'securityCenterPasskeySecondaryReady', 'Crea una clave de acceso en este dispositivo para iniciar sesión sin contraseña.'),
('he', 'securityCenterPasskeySecondaryReady', 'צור מפתח גישה במכשיר הזה כדי להיכנס בלי סיסמה.'),

-- Account has a passkey, but this app/platform cannot run a ceremony here yet
('en', 'securityCenterPasskeyPrimaryAccountReady', 'Your account has a passkey for faster, passwordless sign-in.'),
('es', 'securityCenterPasskeyPrimaryAccountReady', 'Tu cuenta tiene una clave de acceso para un inicio de sesión más rápido y sin contraseña.'),
('he', 'securityCenterPasskeyPrimaryAccountReady', 'לחשבון שלך יש מפתח גישה לכניסה מהירה וללא סיסמה.'),

-- Device is capable; the app is not configured for this platform yet
('en', 'securityCenterPasskeySecondaryAppNotAvailable', 'Passkey sign-in isn''t available in this app on this platform yet.'),
('es', 'securityCenterPasskeySecondaryAppNotAvailable', 'El inicio de sesión con clave de acceso aún no está disponible en esta aplicación en esta plataforma.'),
('he', 'securityCenterPasskeySecondaryAppNotAvailable', 'הכניסה עם מפתח גישה עדיין אינה זמינה באפליקציה הזו בפלטפורמה הזו.'),

-- Session row when the account has passkeys but not usable on this device
('en', 'securityCenterPasskeySessionAccountReady', 'Your account has a passkey for use on supported devices.'),
('es', 'securityCenterPasskeySessionAccountReady', 'Tu cuenta tiene una clave de acceso para usar en dispositivos compatibles.'),
('he', 'securityCenterPasskeySessionAccountReady', 'לחשבון שלך יש מפתח גישה לשימוש במכשירים נתמכים.'),

-- Card chip: passkey exists on the account but cannot be used on this device
('en', 'securityCenterStatusAdded', 'Added'),
('es', 'securityCenterStatusAdded', 'Añadida'),
('he', 'securityCenterStatusAdded', 'נוסף')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
