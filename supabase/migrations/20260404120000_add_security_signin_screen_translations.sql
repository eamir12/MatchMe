-- Migration: Add Security Sign-In Screen Translations
-- This migration adds Spanish and Hebrew translations for all security sign-in screen keys
-- that were previously only available in English as fallback defaults

BEGIN;

-- Security Sign-In Hub (Main Screen)
INSERT INTO translations (key, value, locale) VALUES
  ('securitySignInHubTitle', 'Security & Sign-In', 'en'),
  ('securitySignInHubTitle', 'Seguridad e Inicio de Sesión', 'es'),
  ('securitySignInHubTitle', 'אבטחה וכניסה', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securitySignInHubDescription', 'Manage your account security and sign-in methods', 'en'),
  ('securitySignInHubDescription', 'Administra la seguridad de tu cuenta y los métodos de inicio de sesión', 'es'),
  ('securitySignInHubDescription', 'נהל את אבטחת החשבון וקבל שיטות כניסה', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- Current Session Section
INSERT INTO translations (key, value, locale) VALUES
  ('securityCurrentSessionTitle', 'Your Current Session', 'en'),
  ('securityCurrentSessionTitle', 'Tu sesión actual', 'es'),
  ('securityCurrentSessionTitle', 'ההפעלה הנוכחית שלך', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityHowYouSignedIn', 'How you signed in:', 'en'),
  ('securityHowYouSignedIn', 'Cómo iniciaste sesión:', 'es'),
  ('securityHowYouSignedIn', 'כיצד התחברת:', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securitySessionStarted', 'Session started:', 'en'),
  ('securitySessionStarted', 'Sesión iniciada:', 'es'),
  ('securitySessionStarted', 'ההפעלה החלה:', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityDeviceInfo', 'Device information', 'en'),
  ('securityDeviceInfo', 'Información del dispositivo', 'es'),
  ('securityDeviceInfo', 'מידע על המכשיר', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- Sign-In Methods Section
INSERT INTO translations (key, value, locale) VALUES
  ('securitySignInMethodsTitle', 'Sign-In Methods', 'en'),
  ('securitySignInMethodsTitle', 'Métodos de Inicio de Sesión', 'es'),
  ('securitySignInMethodsTitle', 'שיטות כניסה', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securitySignInMethodsDescription', 'Manage how you log in to your account', 'en'),
  ('securitySignInMethodsDescription', 'Gestiona cómo inicias sesión en tu cuenta', 'es'),
  ('securitySignInMethodsDescription', 'נהל כיצד אתה מתחבר לחשבון שלך', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityMethodConnected', 'Connected', 'en'),
  ('securityMethodConnected', 'Conectado', 'es'),
  ('securityMethodConnected', 'מחובר', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityMethodNotConnected', 'Not connected', 'en'),
  ('securityMethodNotConnected', 'No conectado', 'es'),
  ('securityMethodNotConnected', 'לא מחובר', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityMethodLastChanged', 'Last changed:', 'en'),
  ('securityMethodLastChanged', 'Último cambio:', 'es'),
  ('securityMethodLastChanged', 'שונה לאחרונה:', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- Security Status Summary
INSERT INTO translations (key, value, locale) VALUES
  ('securityStatusSummarySecure', 'Your account is secure', 'en'),
  ('securityStatusSummarySecure', 'Tu cuenta es segura', 'es'),
  ('securityStatusSummarySecure', 'החשבון שלך בטוח', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityStatusSummaryWarning', 'Your account could be more secure', 'en'),
  ('securityStatusSummaryWarning', 'Tu cuenta podría ser más segura', 'es'),
  ('securityStatusSummaryWarning', 'ניתן להפוך את החשבון שלך לבטוח יותר', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityStatusSummarySetupPasskey', 'Set up a passkey for faster, more secure sign-in', 'en'),
  ('securityStatusSummarySetupPasskey', 'Configura una contraseña para un inicio de sesión más rápido y seguro', 'es'),
  ('securityStatusSummarySetupPasskey', 'הגדר מפתח עבור כניסה מהירה וآمنה יותר', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityStatusSummaryEnable2FA', 'Enable 2-factor authentication for additional protection', 'en'),
  ('securityStatusSummaryEnable2FA', 'Habilita la autenticación de dos factores para protección adicional', 'es'),
  ('securityStatusSummaryEnable2FA', 'הפוך את האימות הדו-שלבי לעזור להגנה נוספת', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- Two-Factor Authentication Section
INSERT INTO translations (key, value, locale) VALUES
  ('securityTwoFactorTitle', '2-Factor Authentication', 'en'),
  ('securityTwoFactorTitle', 'Autenticación de Dos Factores', 'es'),
  ('securityTwoFactorTitle', 'אימות דו-שלבי', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityTwoFactorDescription', 'Optional extra verification step for sensitive actions', 'en'),
  ('securityTwoFactorDescription', 'Paso de verificación adicional opcional para acciones sensibles', 'es'),
  ('securityTwoFactorDescription', 'שלב אימות נוסף אופציונלי לפעולות רגישות', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- Active Sessions
INSERT INTO translations (key, value, locale) VALUES
  ('securityActiveSessions', 'Active Sessions', 'en'),
  ('securityActiveSessions', 'Sesiones Activas', 'es'),
  ('securityActiveSessions', 'הפעלות פעילות', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityActiveSessionsDescription', 'View and manage your logged-in devices', 'en'),
  ('securityActiveSessionsDescription', 'Ver y administrar tus dispositivos conectados', 'es'),
  ('securityActiveSessionsDescription', 'צפה וניהול של המכשירים שלך המחוברים', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityCurrentDevice', 'Current device', 'en'),
  ('securityCurrentDevice', 'Dispositivo actual', 'es'),
  ('securityCurrentDevice', 'המכשיר הנוכחי', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityShowAllDevices', 'Show all devices', 'en'),
  ('securityShowAllDevices', 'Mostrar todos los dispositivos', 'es'),
  ('securityShowAllDevices', 'הצג את כל המכשירים', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityRevokeOtherSessions', 'Sign out from other devices', 'en'),
  ('securityRevokeOtherSessions', 'Cerrar sesión en otros dispositivos', 'es'),
  ('securityRevokeOtherSessions', 'התנתק מהמכשירים האחרים', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityRevokeAllSessions', 'Sign out everywhere', 'en'),
  ('securityRevokeAllSessions', 'Cerrar sesión en todas partes', 'es'),
  ('securityRevokeAllSessions', 'התנתק בכל מקום', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- Password Section
INSERT INTO translations (key, value, locale) VALUES
  ('securityPasswordSection', 'Password', 'en'),
  ('securityPasswordSection', 'Contraseña', 'es'),
  ('securityPasswordSection', 'סיסמה', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityPasswordDescription', 'Reset your password to strengthen your account security', 'en'),
  ('securityPasswordDescription', 'Restablece tu contraseña para fortalecer la seguridad de tu cuenta', 'es'),
  ('securityPasswordDescription', 'אפס את הסיסמה שלך כדי לחזק את אבטחת החשבון', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityPasswordLastChanged', 'Last changed: {date}', 'en'),
  ('securityPasswordLastChanged', 'Último cambio: {date}', 'es'),
  ('securityPasswordLastChanged', 'שונה לאחרונה: {date}', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityPasswordNeverChanged', 'Never changed', 'en'),
  ('securityPasswordNeverChanged', 'Nunca cambiada', 'es'),
  ('securityPasswordNeverChanged', 'לא שונתה מעולם', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- Context Help
INSERT INTO translations (key, value, locale) VALUES
  ('securityContextHelpWhatIsPasskey', 'A passkey is a secure alternative to passwords using your device''s biometric or PIN', 'en'),
  ('securityContextHelpWhatIsPasskey', 'Una contraseña es una alternativa segura a las contraseñas que utiliza la biometría o el PIN de tu dispositivo', 'es'),
  ('securityContextHelpWhatIsPasskey', 'סיסמה היא חלופה בטוחה לסיסמאות המשתמשת בביומטריה או PIN של המכשיר שלך', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityContextHelpWhy2FA', '2-factor authentication adds an extra verification step to protect your account', 'en'),
  ('securityContextHelpWhy2FA', 'La autenticación de dos factores añade un paso de verificación adicional para proteger tu cuenta', 'es'),
  ('securityContextHelpWhy2FA', 'אימות דו-שלבי מוסיף שלב אימות נוסף כדי להגן על החשבון שלך', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('securityContextHelpWhyMultiplePasskeys', 'Multiple passkeys let you sign in from different devices without storing passwords', 'en'),
  ('securityContextHelpWhyMultiplePasskeys', 'Las contraseñas múltiples te permiten iniciar sesión desde diferentes dispositivos sin almacenar contraseñas', 'es'),
  ('securityContextHelpWhyMultiplePasskeys', 'סיסמאות מרובות מאפשרות לך להתחבר מהתקנים שונים ללא אחסון סיסמאות', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- Current Sign-In Method
INSERT INTO translations (key, value, locale) VALUES
  ('settingsCurrentSignInMethodTitle', 'Current Sign-In Method', 'en'),
  ('settingsCurrentSignInMethodTitle', 'Método de Inicio de Sesión Actual', 'es'),
  ('settingsCurrentSignInMethodTitle', 'שיטת הכניסה הנוכחית', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('settingsAuthMethodPasskey', 'Passkey', 'en'),
  ('settingsAuthMethodPasskey', 'Contraseña', 'es'),
  ('settingsAuthMethodPasskey', 'סיסמה', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
