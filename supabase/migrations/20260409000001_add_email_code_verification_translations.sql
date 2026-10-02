-- Migration: Add Email Code Verification Translations
-- This adds English, Spanish, and Hebrew translations for the email code verification feature

-- English Translations
INSERT INTO translations (key, locale, value) VALUES 
('settingsMfaEmailCodeSend', 'en', 'Email me a code'),
('settingsMfaEmailCodeSent', 'en', 'Code sent to {email}'),
('settingsMfaEmailCodeSendBody', 'en', 'Enter the code sent to your email'),
('settingsMfaEmailCodeBody', 'en', 'Enter the code we sent to {email}'),
('settingsMfaEmailCodeEnter', 'en', 'Please enter a valid 6-digit code'),
('settingsMfaEmailCodeResend', 'en', 'Resend Email'),
('settingsMfaEmailCodeSendFailed', 'en', 'Failed to send verification email'),
('settingsMfaEmailCodeVerifyFailed', 'en', 'Invalid or expired code'),
('settingsPasswordReauthSentGeneric', 'en', 'Verification code sent')
ON CONFLICT (key, locale) DO UPDATE SET 
  value = EXCLUDED.value,
  updated_at = NOW();

-- Spanish Translations
INSERT INTO translations (key, locale, value) VALUES 
('settingsMfaEmailCodeSend', 'es', 'Envíame un código'),
('settingsMfaEmailCodeSent', 'es', 'Código enviado a {email}'),
('settingsMfaEmailCodeSendBody', 'es', 'Ingresa el código enviado a tu correo'),
('settingsMfaEmailCodeBody', 'es', 'Ingresa el código que enviamos a {email}'),
('settingsMfaEmailCodeEnter', 'es', 'Por favor, ingresa un código válido de 6 dígitos'),
('settingsMfaEmailCodeResend', 'es', 'Reenviar correo'),
('settingsMfaEmailCodeSendFailed', 'es', 'No se pudo enviar el correo de verificación'),
('settingsMfaEmailCodeVerifyFailed', 'es', 'Código inválido o expirado'),
('settingsPasswordReauthSentGeneric', 'es', 'Código de verificación enviado')
ON CONFLICT (key, locale) DO UPDATE SET 
  value = EXCLUDED.value,
  updated_at = NOW();

-- Hebrew Translations
INSERT INTO translations (key, locale, value) VALUES 
('settingsMfaEmailCodeSend', 'he', 'שלח לי קוד'),
('settingsMfaEmailCodeSent', 'he', 'קוד נשלח אל {email}'),
('settingsMfaEmailCodeSendBody', 'he', 'הזן את הקוד שנשלח לדוא״ל שלך'),
('settingsMfaEmailCodeBody', 'he', 'הזן את הקוד ששלחנו אל {email}'),
('settingsMfaEmailCodeEnter', 'he', 'אנא הזן קוד תקף בן 6 ספרות'),
('settingsMfaEmailCodeResend', 'he', 'שלח דוא״ל שוב'),
('settingsMfaEmailCodeSendFailed', 'he', 'לא ניתן היה לשלוח דוא״ל אימות'),
('settingsMfaEmailCodeVerifyFailed', 'he', 'קוד לא חוקי או שפג תוקפו'),
('settingsPasswordReauthSentGeneric', 'he', 'קוד אימות נשלח')
ON CONFLICT (key, locale) DO UPDATE SET 
  value = EXCLUDED.value,
  updated_at = NOW();
