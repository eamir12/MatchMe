INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'authLogoutConfirmTitle', 'Log out?'),
  ('en', 'authLogoutConfirmBody', 'You’ll need to sign in again to access your account.'),
  ('es', 'authLogoutConfirmTitle', '¿Cerrar sesión?'),
  ('es', 'authLogoutConfirmBody', 'Tendrás que iniciar sesión de nuevo para acceder a tu cuenta.'),
  ('he', 'authLogoutConfirmTitle', 'להתנתק?'),
  ('he', 'authLogoutConfirmBody', 'תצטרכו להיכנס שוב כדי לגשת לחשבון שלכם.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
