BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsMfaRecoveryCodesAndEmailDescription', $$Recovery codes are one-time backup codes. If you cannot access them, you can also request a one-time code by email at {email}.$$),
    ('es', 'settingsMfaRecoveryCodesAndEmailDescription', $$Los códigos de recuperación son códigos de respaldo de un solo uso. Si no puedes acceder a ellos, también puedes pedir un código de un solo uso por correo a {email}.$$),
    ('he', 'settingsMfaRecoveryCodesAndEmailDescription', $$קודי שחזור הם קודי גיבוי חד-פעמיים. אם אין לך גישה אליהם, אפשר גם לבקש קוד חד-פעמי בדוא״ל לכתובת {email}.$$),
    ('en', 'settingsMfaUseEmailCode', $$Use email code instead$$),
    ('es', 'settingsMfaUseEmailCode', $$Usar código por correo$$),
    ('he', 'settingsMfaUseEmailCode', $$השתמש בקוד שנשלח בדוא״ל במקום$$),
    ('en', 'settingsMfaEmailFallbackAvailable', $$Email backup available: {email}$$),
    ('es', 'settingsMfaEmailFallbackAvailable', $$Respaldo por correo disponible: {email}$$),
    ('he', 'settingsMfaEmailFallbackAvailable', $$גיבוי בדוא״ל זמין: {email}$$),
    ('en', 'settingsMfaEmailCode', $$Email code$$),
    ('es', 'settingsMfaEmailCode', $$Código por correo$$),
    ('he', 'settingsMfaEmailCode', $$קוד בדוא״ל$$),
    ('en', 'settingsMfaEmailCodeBody', $$Enter the 6-digit code sent to {email} to continue.$$),
    ('es', 'settingsMfaEmailCodeBody', $$Ingresa el código de 6 dígitos enviado a {email} para continuar.$$),
    ('he', 'settingsMfaEmailCodeBody', $$הזן את הקוד בן 6 הספרות שנשלח אל {email} כדי להמשיך.$$),
    ('en', 'settingsMfaEmailCodeSend', $$Email me a code$$),
    ('es', 'settingsMfaEmailCodeSend', $$Envíame un código$$),
    ('he', 'settingsMfaEmailCodeSend', $$שלח לי קוד בדוא״ל$$),
    ('en', 'settingsMfaEmailCodeSent', $$A verification code was sent to {email}$$),
    ('es', 'settingsMfaEmailCodeSent', $$Se envió un código de verificación a {email}$$),
    ('he', 'settingsMfaEmailCodeSent', $$קוד אימות נשלח אל {email}$$),
    ('en', 'settingsMfaEmailCodeResend', $$Resend email code$$),
    ('es', 'settingsMfaEmailCodeResend', $$Reenviar código por correo$$),
    ('he', 'settingsMfaEmailCodeResend', $$שלח שוב קוד בדוא״ל$$),
    ('en', 'settingsMfaEmailCodeResendIn', $$Resend in {seconds} seconds$$),
    ('es', 'settingsMfaEmailCodeResendIn', $$Reenviar en {seconds} segundos$$),
    ('he', 'settingsMfaEmailCodeResendIn', $$אפשר לשלוח שוב בעוד {seconds} שניות$$),
    ('en', 'settingsMfaEmailCodeEnter', $$Enter a valid 6-digit email code$$),
    ('es', 'settingsMfaEmailCodeEnter', $$Ingresa un código válido de 6 dígitos$$),
    ('he', 'settingsMfaEmailCodeEnter', $$הזן קוד אימות תקין בן 6 ספרות$$),
    ('en', 'settingsMfaEmailCodeSendFailed', $$Failed to send email code$$),
    ('es', 'settingsMfaEmailCodeSendFailed', $$No se pudo enviar el código por correo$$),
    ('he', 'settingsMfaEmailCodeSendFailed', $$לא הצלחנו לשלוח את הקוד בדוא״ל$$),
    ('en', 'settingsMfaEmailCodeVerifyFailed', $$Invalid email verification code$$),
    ('es', 'settingsMfaEmailCodeVerifyFailed', $$Código de verificación por correo inválido$$),
    ('he', 'settingsMfaEmailCodeVerifyFailed', $$קוד האימות מהדוא״ל אינו תקין$$)
)
INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), translation_values.locale, translation_values.key, translation_values.value, now(), now()
FROM translation_values
WHERE NOT EXISTS (
  SELECT 1
  FROM translations t
  WHERE t.locale = translation_values.locale
    AND t.key = translation_values.key
);

COMMIT;
