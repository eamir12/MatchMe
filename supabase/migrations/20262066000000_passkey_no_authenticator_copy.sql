INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'authPasskeyNoAuthenticatorTitle', 'Passkey not set up on this PC'),
  ('en', 'authPasskeyNoAuthenticatorBody', 'This PC has no fingerprint, face or PIN sign-in set up, so the passkey can’t be checked here. Use your password, plug in a security key, or sign in on the device where you created the passkey (for example, your phone).'),
  ('es', 'authPasskeyNoAuthenticatorTitle', 'La clave de acceso no está configurada en este equipo'),
  ('es', 'authPasskeyNoAuthenticatorBody', 'Este equipo no tiene configurado el inicio de sesión con huella, rostro o PIN, por lo que la clave de acceso no se puede verificar aquí. Usa tu contraseña, conecta una llave de seguridad o inicia sesión en el dispositivo donde creaste la clave de acceso (por ejemplo, tu teléfono).'),
  ('he', 'authPasskeyNoAuthenticatorTitle', 'מפתח הגישה לא מוגדר במחשב הזה'),
  ('he', 'authPasskeyNoAuthenticatorBody', 'במחשב הזה לא מוגדרת כניסה עם טביעת אצבע, זיהוי פנים או קוד PIN, ולכן לא ניתן לאמת את מפתח הגישה כאן. אפשר להשתמש בסיסמה, לחבר מפתח אבטחה, או להתחבר במכשיר שבו נוצר מפתח הגישה (למשל הטלפון שלך).')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
