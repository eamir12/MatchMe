INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'authInvalidCredentials', $$Invalid email or password.$$),
  ('es', 'authInvalidCredentials', $$Correo o contrasena invalidos.$$),
  ('he', 'authInvalidCredentials', $$האימייל או הסיסמה שגויים.$$),

  ('en', 'authEmailNotConfirmed', $$Please confirm your email before logging in.$$),
  ('es', 'authEmailNotConfirmed', $$Confirma tu correo electronico antes de iniciar sesion.$$),
  ('he', 'authEmailNotConfirmed', $$יש לאשר את כתובת האימייל לפני ההתחברות.$$),

  ('en', 'authNetworkError', $$Unable to reach the server. Check your connection and try again.$$),
  ('es', 'authNetworkError', $$No se puede conectar al servidor. Revisa tu conexion e intentalo de nuevo.$$),
  ('he', 'authNetworkError', $$לא ניתן להתחבר לשרת. בדקו את החיבור ונסו שוב.$$),

  ('en', 'authLoginServiceError', $$Login is temporarily unavailable. Please try again in a moment.$$),
  ('es', 'authLoginServiceError', $$El inicio de sesion no esta disponible temporalmente. Intentalo de nuevo en breve.$$),
  ('he', 'authLoginServiceError', $$ההתחברות אינה זמינה זמנית. נסו שוב בעוד רגע.$$)
ON CONFLICT (locale, key) DO UPDATE
SET value = EXCLUDED.value;
