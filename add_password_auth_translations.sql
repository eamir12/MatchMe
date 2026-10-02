-- Migration: Add Security & Authentication Translation Keys
-- This adds English, Spanish, and Hebrew translations for the new Security & Sign-In Hub
-- and password/authentication management features

-- English Translations
INSERT INTO translations (key, locale, value) VALUES 
('settingsPasswordChangeSuccess', 'en', 'Password changed successfully'),
('settingsNewPassword', 'en', 'New Password'),
('settingsPasswordReauthBody', 'en', 'Enter your new password'),
('settingsMfaSecretMissing', 'en', 'Failed to retrieve authenticator secret'),
('settingsMfaInitializing', 'en', 'Setting up authenticator app...'),
('settingsMfaSetupInstruction', 'en', 'Scan the QR code with your authenticator app, or enter the code manually'),
('settingsMfaCopied', 'en', 'Code copied to clipboard'),
('settingsMfaCodeInvalid', 'en', 'Invalid code. Please try again.'),
('settingsMfaChallengeTitle', 'en', 'Verify with 2FA'),
('settingsMfaChallengeBody', 'en', 'Enter your 6-digit authentication code'),
('settingsMfaChallengeInvalid', 'en', 'Invalid code. Please try again.'),
('settingsMfaChallengeFailed', 'en', 'Verification failed. Please try again.'),
('settingsMfaChallengeNotVerified', 'en', 'Verification failed'),
('settingsMfaNotEnabled', 'en', '2-Factor authentication is not enabled'),
('settingsPasskeyEnrollSuccess', 'en', 'Passkey added successfully'),
('settingsPasskeyEnrollFailed', 'en', 'Failed to add passkey'),
('settingsPasskeyRemoveSuccess', 'en', 'Passkey removed successfully'),
('settingsPasskeyRemoveConfirm', 'en', 'Remove all passkeys from your account? You''ll need to use another sign-in method.'),
('generalUnknown', 'en', 'Unknown'),
('generalFieldRequired', 'en', 'This field is required')
ON CONFLICT (key, locale) DO UPDATE SET 
  value = EXCLUDED.value,
  updated_at = NOW();

-- Spanish Translations
INSERT INTO translations (key, locale, value) VALUES 
('settingsPasswordChangeSuccess', 'es', 'Contraseña cambiada exitosamente'),
('settingsNewPassword', 'es', 'Nueva Contraseña'),
('settingsPasswordReauthBody', 'es', 'Ingresa tu nueva contraseña'),
('settingsMfaSecretMissing', 'es', 'No se pudo recuperar el secreto del autenticador'),
('settingsMfaInitializing', 'es', 'Configurando aplicación autenticadora...'),
('settingsMfaSetupInstruction', 'es', 'Escanea el código QR con tu aplicación autenticadora o ingresa el código manualmente'),
('settingsMfaCopied', 'es', 'Código copiado al portapapeles'),
('settingsMfaCodeInvalid', 'es', 'Código inválido. Por favor, intenta de nuevo.'),
('settingsMfaChallengeTitle', 'es', 'Verificar con 2FA'),
('settingsMfaChallengeBody', 'es', 'Ingresa tu código de autenticación de 6 dígitos'),
('settingsMfaChallengeInvalid', 'es', 'Código inválido. Por favor, intenta de nuevo.'),
('settingsMfaChallengeFailed', 'es', 'Verificación fallida. Por favor, intenta de nuevo.'),
('settingsMfaChallengeNotVerified', 'es', 'Verificación fallida'),
('settingsMfaNotEnabled', 'es', 'La autenticación de 2 factores no está habilitada'),
('settingsPasskeyEnrollSuccess', 'es', 'Contraseña enviada exitosamente'),
('settingsPasskeyEnrollFailed', 'es', 'No se pudo agregar la contraseña enviada'),
('settingsPasskeyRemoveSuccess', 'es', 'Contraseña enviada eliminada exitosamente'),
('settingsPasskeyRemoveConfirm', 'es', '¿Eliminar todas las contraseñas enviadas de tu cuenta? Deberás usar otro método de inicio de sesión.'),
('generalUnknown', 'es', 'Desconocido'),
('generalFieldRequired', 'es', 'Este campo es obligatorio')
ON CONFLICT (key, locale) DO UPDATE SET 
  value = EXCLUDED.value,
  updated_at = NOW();

-- Hebrew Translations
INSERT INTO translations (key, locale, value) VALUES 
('settingsPasswordChangeSuccess', 'he', 'הסיסמה שונתה בהצלחה'),
('settingsNewPassword', 'he', 'סיסמה חדשה'),
('settingsPasswordReauthBody', 'he', 'הזן את הסיסמה החדשה שלך'),
('settingsMfaSecretMissing', 'he', 'לא ניתן היה לאחזר את סוד ההאחד'),
('settingsMfaInitializing', 'he', 'הגדרת אפליקציית ההאחד...'),
('settingsMfaSetupInstruction', 'he', 'סרוק את קוד QR באמצעות אפליקציית ההאחד שלך או הזן את הקוד ידנית'),
('settingsMfaCopied', 'he', 'הקוד הועתק ללוח'),
('settingsMfaCodeInvalid', 'he', 'קוד לא חוקי. נא לנסות שוב.'),
('settingsMfaChallengeTitle', 'he', 'אימות עם 2FA'),
('settingsMfaChallengeBody', 'he', 'הזן את שם ההאחד שלך בן 6 ספרות'),
('settingsMfaChallengeInvalid', 'he', 'קוד לא חוקי. נא לנסות שוב.'),
('settingsMfaChallengeFailed', 'he', 'האימות נכשל. נא לנסות שוב.'),
('settingsMfaChallengeNotVerified', 'he', 'האימות נכשל'),
('settingsMfaNotEnabled', 'he', 'אימות דו-גורמי אינו ממוכן'),
('settingsPasskeyEnrollSuccess', 'he', 'מקש כניסה נוסף בהצלחה'),
('settingsPasskeyEnrollFailed', 'he', 'לא ניתן להוסיף מקש כניסה'),
('settingsPasskeyRemoveSuccess', 'he', 'מקש כניסה הוסר בהצלחה'),
('settingsPasskeyRemoveConfirm', 'he', 'הסר את כל מקשי הכניסה מחשבונך? תצטרך להשתמש בשיטת כניסה אחרת.'),
('generalUnknown', 'he', 'לא ידוע'),
('generalFieldRequired', 'he', 'שדה זה נדרש')
ON CONFLICT (key, locale) DO UPDATE SET 
  value = EXCLUDED.value,
  updated_at = NOW();
