BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsChangeEmailTitle', 'Change Email Address'),
    ('es', 'settingsChangeEmailTitle', 'Cambiar Dirección de Correo Electrónico'),
    ('he', 'settingsChangeEmailTitle', 'שנה כתובת דוא"ל'),
    
    ('en', 'settingsChangeEmailDescription', 'You''ll need to verify your identity with MFA and confirm your new email address.'),
    ('es', 'settingsChangeEmailDescription', 'Deberás verificar tu identidad con MFA y confirmar tu nueva dirección de correo electrónico.'),
    ('he', 'settingsChangeEmailDescription', 'תצטרך לאמת את זהותך עם MFA ולאשר את כתובת הדוא"ל החדשה שלך.'),
    
    ('en', 'settingsChangeEmailCurrentEmail', 'Current Email'),
    ('es', 'settingsChangeEmailCurrentEmail', 'Correo Electrónico Actual'),
    ('he', 'settingsChangeEmailCurrentEmail', 'דוא"ל נוכחי'),
    
    ('en', 'settingsChangeEmailNewEmail', 'New Email Address'),
    ('es', 'settingsChangeEmailNewEmail', 'Nueva Dirección de Correo Electrónico'),
    ('he', 'settingsChangeEmailNewEmail', 'כתובת דוא"ל חדשה'),
    
    ('en', 'settingsChangeEmailNewEmailHint', 'Enter your new email address'),
    ('es', 'settingsChangeEmailNewEmailHint', 'Ingresa tu nueva dirección de correo electrónico'),
    ('he', 'settingsChangeEmailNewEmailHint', 'הזן את כתובת הדוא"ל החדשה שלך'),
    
    ('en', 'settingsChangeEmailStep1Title', 'Step 1: Verify Your Identity'),
    ('es', 'settingsChangeEmailStep1Title', 'Paso 1: Verifica Tu Identidad'),
    ('he', 'settingsChangeEmailStep1Title', 'שלב 1: אמת את זהותך'),
    
    ('en', 'settingsChangeEmailStep1Description', 'We need to verify you with MFA before changing your email.'),
    ('es', 'settingsChangeEmailStep1Description', 'Necesitamos verificarte con MFA antes de cambiar tu correo electrónico.'),
    ('he', 'settingsChangeEmailStep1Description', 'אנחנו צריכים לאמת אותך עם MFA לפני שינוי הדוא"ל שלך.'),
    
    ('en', 'settingsChangeEmailStep2Title', 'Step 2: Confirm New Email'),
    ('es', 'settingsChangeEmailStep2Title', 'Paso 2: Confirma Tu Nuevo Correo Electrónico'),
    ('he', 'settingsChangeEmailStep2Title', 'שלב 2: אשר את הדוא"ל החדש שלך'),
    
    ('en', 'settingsChangeEmailStep2Description', 'We''ve sent a verification code to your new email address. Enter it below to confirm.'),
    ('es', 'settingsChangeEmailStep2Description', 'Hemos enviado un código de verificación a tu nueva dirección de correo electrónico. Ingresa el código a continuación para confirmar.'),
    ('he', 'settingsChangeEmailStep2Description', 'שלחנו קוד אימות לכתובת הדוא"ל החדשה שלך. הזן אותו להלן כדי לאשר.'),
    
    ('en', 'settingsChangeEmailVerificationCode', 'Verification Code'),
    ('es', 'settingsChangeEmailVerificationCode', 'Código de Verificación'),
    ('he', 'settingsChangeEmailVerificationCode', 'קוד אימות'),
    
    ('en', 'settingsChangeEmailVerificationCodeHint', 'Enter the 6-digit code'),
    ('es', 'settingsChangeEmailVerificationCodeHint', 'Ingresa el código de 6 dígitos'),
    ('he', 'settingsChangeEmailVerificationCodeHint', 'הזן את קוד 6 הספרות'),
    
    ('en', 'settingsChangeEmailSendCode', 'Send Verification Code'),
    ('es', 'settingsChangeEmailSendCode', 'Enviar Código de Verificación'),
    ('he', 'settingsChangeEmailSendCode', 'שלח קוד אימות'),
    
    ('en', 'settingsChangeEmailVerifyCode', 'Verify Code'),
    ('es', 'settingsChangeEmailVerifyCode', 'Verificar Código'),
    ('he', 'settingsChangeEmailVerifyCode', 'אמת קוד'),
    
    ('en', 'settingsChangeEmailCancel', 'Cancel'),
    ('es', 'settingsChangeEmailCancel', 'Cancelar'),
    ('he', 'settingsChangeEmailCancel', 'בטל'),
    
    ('en', 'settingsChangeEmailSuccess', 'Email address changed successfully!'),
    ('es', 'settingsChangeEmailSuccess', '¡Dirección de correo electrónico cambiada exitosamente!'),
    ('he', 'settingsChangeEmailSuccess', 'כתובת הדוא"ל שונתה בהצלחה!'),
    
    ('en', 'settingsChangeEmailError', 'Failed to change email address. Please try again.'),
    ('es', 'settingsChangeEmailError', 'Error al cambiar la dirección de correo electrónico. Por favor, intenta de nuevo.'),
    ('he', 'settingsChangeEmailError', 'שגיאה בשינוי כתובת הדוא"ל. אנא נסה שוב.'),
    
    ('en', 'settingsChangeEmailInvalidEmail', 'Please enter a valid email address.'),
    ('es', 'settingsChangeEmailInvalidEmail', 'Por favor, ingresa una dirección de correo electrónico válida.'),
    ('he', 'settingsChangeEmailInvalidEmail', 'אנא הזן כתובת דוא"ל תקינה.'),
    
    ('en', 'settingsChangeEmailSameEmail', 'New email must be different from current email.'),
    ('es', 'settingsChangeEmailSameEmail', 'El nuevo correo electrónico debe ser diferente del correo electrónico actual.'),
    ('he', 'settingsChangeEmailSameEmail', 'הדוא"ל החדש חייב להיות שונה מהדוא"ל הנוכחי.'),
    
    ('en', 'settingsChangeEmailCodeExpired', 'Verification code has expired. Please request a new one.'),
    ('es', 'settingsChangeEmailCodeExpired', 'El código de verificación ha expirado. Por favor, solicita uno nuevo.'),
    ('he', 'settingsChangeEmailCodeExpired', 'קוד האימות פג תוקף. אנא בקש אחד חדש.'),
    
    ('en', 'settingsChangeEmailInvalidCode', 'Invalid verification code. Please try again.'),
    ('es', 'settingsChangeEmailInvalidCode', 'Código de verificación inválido. Por favor, intenta de nuevo.'),
    ('he', 'settingsChangeEmailInvalidCode', 'קוד אימות לא תקין. אנא נסה שוב.'),
    
    ('en', 'settingsChangeEmailResendCode', 'Resend Code'),
    ('es', 'settingsChangeEmailResendCode', 'Reenviar Código'),
    ('he', 'settingsChangeEmailResendCode', 'שלח קוד שוב'),
    
    ('en', 'settingsChangeEmailCodeSent', 'Verification code sent to your new email address.'),
    ('es', 'settingsChangeEmailCodeSent', 'Código de verificación enviado a tu nueva dirección de correo electrónico.'),
    ('he', 'settingsChangeEmailCodeSent', 'קוד אימות נשלח לכתובת הדוא"ל החדשה שלך.'),
    
    ('en', 'settingsChangeEmailMfaRequired', 'MFA verification required to change email.'),
    ('es', 'settingsChangeEmailMfaRequired', 'Se requiere verificación MFA para cambiar el correo electrónico.'),
    ('he', 'settingsChangeEmailMfaRequired', 'נדרשת אימות MFA כדי לשנות דוא"ל.'),
    
    ('en', 'settingsChangeEmailVerifyCodeTitle', 'Verify Your New Email'),
    ('es', 'settingsChangeEmailVerifyCodeTitle', 'Verifica Tu Nuevo Correo Electrónico'),
    ('he', 'settingsChangeEmailVerifyCodeTitle', 'אמת את הדוא"ל החדש שלך'),
    
    ('en', 'settingsChangeEmailVerifyCodeDescription', 'We''ve sent a verification code to your new email address. Enter it below to confirm the change.'),
    ('es', 'settingsChangeEmailVerifyCodeDescription', 'Hemos enviado un código de verificación a tu nueva dirección de correo electrónico. Ingresa el código a continuación para confirmar el cambio.'),
    ('he', 'settingsChangeEmailVerifyCodeDescription', 'שלחנו קוד אימות לכתובת הדוא"ל החדשה שלך. הזן אותו להלן כדי לאשר את השינוי.'),
    
    ('en', 'settingsChangeEmailCode', 'Verification Code'),
    ('es', 'settingsChangeEmailCode', 'Código de Verificación'),
    ('he', 'settingsChangeEmailCode', 'קוד אימות'),
    
    ('en', 'settingsChangeEmailCodeExpires', 'Code expires in'),
    ('es', 'settingsChangeEmailCodeExpires', 'El código expira en'),
    ('he', 'settingsChangeEmailCodeExpires', 'הקוד יפוג בעוד'),
    
    ('en', 'settingsChangeEmailCodeResent', 'Verification code resent to your new email.'),
    ('es', 'settingsChangeEmailCodeResent', 'Código de verificación reenviado a tu nuevo correo electrónico.'),
    ('he', 'settingsChangeEmailCodeResent', 'קוד האימות נשלח שוב לדוא"ל החדש שלך.'),
    
    ('en', 'settingsChangeEmailVerify', 'Verify and Change Email'),
    ('es', 'settingsChangeEmailVerify', 'Verificar y Cambiar Correo Electrónico'),
    ('he', 'settingsChangeEmailVerify', 'אמת ושנה דוא"ל'),
    
    ('en', 'settingsChangeEmailEmailInUse', 'This email address is already in use'),
    ('es', 'settingsChangeEmailEmailInUse', 'Esta dirección de correo electrónico ya está en uso'),
    ('he', 'settingsChangeEmailEmailInUse', 'כתובת דוא"ל זו כבר בשימוש')
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
