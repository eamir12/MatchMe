BEGIN;

INSERT INTO translations (key, locale, value) VALUES
('authEmailAlreadyRegistered', 'en', 'An account with this email already exists.'),
('authDisposableEmailBlocked', 'en', 'Please use a regular personal email address. Temporary or disposable email addresses are not supported.'),
('authEmailRejected', 'en', 'We couldn''t use that email address for registration. Please try a different email.'),
('authPasswordLockedUntilEmailApproved', 'en', 'Enter an approved email address to continue.'),
('authSignupCodeTitle', 'en', 'Verify your email'),
('authSignupCodeBody', 'en', 'Enter the 6-digit code we sent to {email} to finish creating your account.'),
('authSignupCodeLabel', 'en', 'Verification code'),
('authSignupCodeHint', 'en', '6-digit code'),
('authSignupCodeEnterPrompt', 'en', 'Enter the 6-digit code from your email'),
('authSignupCodeVerify', 'en', 'Verify email'),
('authSignupCodeResend', 'en', 'Resend code'),
('authSignupCodeBackToLogin', 'en', 'Back'),
('authSignupCodeInvalid', 'en', 'That verification code is not valid.'),
('authSignupCodeExpired', 'en', 'That verification code has expired. Request a new one.'),
('authSignupCodeVerifyFailed', 'en', 'We could not verify that code. Please try again.'),
('authSignupCodeResendFailed', 'en', 'We could not resend the verification code.'),
('authSignupCodeResent', 'en', 'A new verification code was sent to {email}.'),
('authSignupCodeRateLimited', 'en', 'A code was sent recently. Please wait a moment before trying again.')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

INSERT INTO translations (key, locale, value) VALUES
('authEmailAlreadyRegistered', 'es', 'Ya existe una cuenta con este correo electrónico.'),
('authDisposableEmailBlocked', 'es', 'Usa una dirección de correo personal normal. No se admiten correos temporales o desechables.'),
('authEmailRejected', 'es', 'No pudimos usar esa dirección de correo para el registro. Intenta con otra dirección.'),
('authPasswordLockedUntilEmailApproved', 'es', 'Ingresa una dirección de correo aprobada para continuar.'),
('authSignupCodeTitle', 'es', 'Verifica tu correo'),
('authSignupCodeBody', 'es', 'Ingresa el código de 6 dígitos que enviamos a {email} para terminar de crear tu cuenta.'),
('authSignupCodeLabel', 'es', 'Código de verificación'),
('authSignupCodeHint', 'es', 'Código de 6 dígitos'),
('authSignupCodeEnterPrompt', 'es', 'Ingresa el código de 6 dígitos de tu correo'),
('authSignupCodeVerify', 'es', 'Verificar correo'),
('authSignupCodeResend', 'es', 'Reenviar código'),
('authSignupCodeBackToLogin', 'es', 'Volver'),
('authSignupCodeInvalid', 'es', 'Ese código de verificación no es válido.'),
('authSignupCodeExpired', 'es', 'Ese código de verificación ha expirado. Solicita uno nuevo.'),
('authSignupCodeVerifyFailed', 'es', 'No pudimos verificar ese código. Inténtalo de nuevo.'),
('authSignupCodeResendFailed', 'es', 'No pudimos reenviar el código de verificación.'),
('authSignupCodeResent', 'es', 'Se envió un nuevo código de verificación a {email}.'),
('authSignupCodeRateLimited', 'es', 'Se envió un código hace poco. Espera un momento antes de intentarlo otra vez.')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

INSERT INTO translations (key, locale, value) VALUES
('authEmailAlreadyRegistered', 'he', 'כבר קיים חשבון עם כתובת הדוא״ל הזו.'),
('authDisposableEmailBlocked', 'he', 'אנא השתמשו בכתובת דוא״ל אישית רגילה. כתובות דוא״ל זמניות או חד-פעמיות אינן נתמכות.'),
('authEmailRejected', 'he', 'לא הצלחנו להשתמש בכתובת הדוא״ל הזו להרשמה. נסו כתובת אחרת.'),
('authPasswordLockedUntilEmailApproved', 'he', 'הזינו כתובת דוא״ל מאושרת כדי להמשיך.'),
('authSignupCodeTitle', 'he', 'אמתו את הדוא״ל שלכם'),
('authSignupCodeBody', 'he', 'הזינו את הקוד בן 6 הספרות ששלחנו אל {email} כדי לסיים ליצור את החשבון שלכם.'),
('authSignupCodeLabel', 'he', 'קוד אימות'),
('authSignupCodeHint', 'he', 'קוד בן 6 ספרות'),
('authSignupCodeEnterPrompt', 'he', 'הזינו את הקוד בן 6 הספרות מהדוא״ל שלכם'),
('authSignupCodeVerify', 'he', 'אמתו דוא״ל'),
('authSignupCodeResend', 'he', 'שלחו שוב קוד'),
('authSignupCodeBackToLogin', 'he', 'חזרה'),
('authSignupCodeInvalid', 'he', 'קוד האימות הזה אינו תקין.'),
('authSignupCodeExpired', 'he', 'תוקף קוד האימות הזה פג. בקשו קוד חדש.'),
('authSignupCodeVerifyFailed', 'he', 'לא הצלחנו לאמת את הקוד הזה. נסו שוב.'),
('authSignupCodeResendFailed', 'he', 'לא הצלחנו לשלוח שוב את קוד האימות.'),
('authSignupCodeResent', 'he', 'קוד אימות חדש נשלח אל {email}.'),
('authSignupCodeRateLimited', 'he', 'קוד נשלח לאחרונה. אנא המתינו רגע לפני שתנסו שוב.')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
