INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'authOAuthProviderFailed', $$There was a problem logging in using {provider}.$$),
  ('es', 'authOAuthProviderFailed', $$Hubo un problema al iniciar sesión usando {provider}.$$),
  ('he', 'authOAuthProviderFailed', $$הייתה בעיה בהתחברות באמצעות {provider}.$$),

  ('en', 'authOAuthSuggestionPasskey', 'You can also try using a passkey.'),
  ('es', 'authOAuthSuggestionPasskey', 'También puedes intentar con una clave de acceso.'),
  ('he', 'authOAuthSuggestionPasskey', 'ניתן גם לנסות להשתמש במפתח גישה.'),

  ('en', 'authOAuthSuggestionDifferentProvider', 'You can also try a different login provider.'),
  ('es', 'authOAuthSuggestionDifferentProvider', 'También puedes intentar con un proveedor de inicio de sesión diferente.'),
  ('he', 'authOAuthSuggestionDifferentProvider', 'ניתן גם לנסות עם ספק התחברות אחר.'),

  ('en', 'authOAuthSuggestionPassword', 'You can also try username and password.'),
  ('es', 'authOAuthSuggestionPassword', 'También puedes intentar con nombre de usuario y contraseña.'),
  ('he', 'authOAuthSuggestionPassword', 'ניתן גם לנסות עם שם משתמש וסיסמה.')
ON CONFLICT (locale, key) DO UPDATE
SET value = EXCLUDED.value;