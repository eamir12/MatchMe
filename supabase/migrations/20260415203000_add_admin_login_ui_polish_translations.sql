INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'authEmailInvalid', $$Enter a valid email address.$$),
  ('es', 'authEmailInvalid', $$Ingresa una direccion de correo valida.$$),
  ('he', 'authEmailInvalid', $$יש להזין כתובת אימייל תקינה.$$),

  ('en', 'authPasswordShow', $$Show password$$),
  ('es', 'authPasswordShow', $$Mostrar contrasena$$),
  ('he', 'authPasswordShow', $$הצגת סיסמה$$),

  ('en', 'authPasswordHide', $$Hide password$$),
  ('es', 'authPasswordHide', $$Ocultar contrasena$$),
  ('he', 'authPasswordHide', $$הסתרת סיסמה$$),

  ('en', 'authSigningIn', $$Signing in...$$),
  ('es', 'authSigningIn', $$Iniciando sesion...$$),
  ('he', 'authSigningIn', $$מתחבר...$$),

  ('en', 'adminLoginSubtitle', $$Sign in with your authorized admin account.$$),
  ('es', 'adminLoginSubtitle', $$Inicia sesion con tu cuenta de administrador autorizada.$$),
  ('he', 'adminLoginSubtitle', $$התחברו עם חשבון המנהל המורשה שלכם.$$),

  ('en', 'adminLoginAuthorizedOnly', $$Authorized admins only$$),
  ('es', 'adminLoginAuthorizedOnly', $$Solo administradores autorizados$$),
  ('he', 'adminLoginAuthorizedOnly', $$למנהלים מורשים בלבד$$),

  ('en', 'adminLoginHelper', $$Use the same email and password linked to your MatchMe admin access.$$),
  ('es', 'adminLoginHelper', $$Usa el mismo correo y contrasena vinculados a tu acceso administrativo de MatchMe.$$),
  ('he', 'adminLoginHelper', $$השתמשו באותו אימייל ואותה סיסמה שמקושרים לגישת הניהול שלכם ב-MatchMe.$$),

  ('en', 'adminLoginRememberEmail', $$Remember this email on this device$$),
  ('es', 'adminLoginRememberEmail', $$Recordar este correo en este dispositivo$$),
  ('he', 'adminLoginRememberEmail', $$לזכור את האימייל הזה במכשיר זה$$),

  ('en', 'adminLoginRetry', $$Try again$$),
  ('es', 'adminLoginRetry', $$Intentarlo de nuevo$$),
  ('he', 'adminLoginRetry', $$לנסות שוב$$),

  ('en', 'adminLoginTroubleTitle', $$Having trouble signing in?$$),
  ('es', 'adminLoginTroubleTitle', $$Tienes problemas para iniciar sesion?$$),
  ('he', 'adminLoginTroubleTitle', $$נתקלתם בבעיה בהתחברות?$$),

  ('en', 'adminLoginTroubleBody', $$Check your connection, confirm your email if needed, and make sure this account has admin access.$$),
  ('es', 'adminLoginTroubleBody', $$Revisa tu conexion, confirma tu correo si hace falta y asegurate de que esta cuenta tenga acceso administrativo.$$),
  ('he', 'adminLoginTroubleBody', $$בדקו את החיבור, אשרו את האימייל אם צריך, וודאו שלחשבון הזה יש גישת ניהול.$$)
ON CONFLICT (locale, key) DO UPDATE
SET value = EXCLUDED.value;
