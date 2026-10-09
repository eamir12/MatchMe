BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('authPasskeySetupAndroidLoginTitle', 'Passkeys aren''t set up on this Android device', 'en'),
  ('authPasskeySetupIosLoginTitle', 'Passkeys aren''t set up on this iPhone', 'en'),
  ('authPasskeySetupWindowsLoginTitle', 'Passkeys aren''t set up on this Windows PC', 'en'),
  ('authPasskeySetupWebLoginTitle', 'Passkeys aren''t set up in this browser', 'en'),
  ('authPasskeySetupPasswordAlternative', 'You can sign in with your username and password instead.', 'en'),
  ('authPasskeySetupMoreInfoButton', 'More information', 'en'),
  ('authPasskeySetupWebInstructionsTitle', 'About passkeys in this browser', 'en'),
  ('authPasskeySetupWebInstructionsBody', 'Passkey availability in a browser depends on your browser, device, and saved passkey provider. Check that your browser supports passkeys and that a passkey is available in your password manager. You can also sign in with your username and password.', 'en')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('authPasskeySetupAndroidLoginTitle', 'Las llaves de acceso no están configuradas en este dispositivo Android', 'es'),
  ('authPasskeySetupIosLoginTitle', 'Las llaves de acceso no están configuradas en este iPhone', 'es'),
  ('authPasskeySetupWindowsLoginTitle', 'Las llaves de acceso no están configuradas en este PC con Windows', 'es'),
  ('authPasskeySetupWebLoginTitle', 'Las llaves de acceso no están configuradas en este navegador', 'es'),
  ('authPasskeySetupPasswordAlternative', 'Puedes iniciar sesión con tu nombre de usuario y contraseña.', 'es'),
  ('authPasskeySetupMoreInfoButton', 'Más información', 'es'),
  ('authPasskeySetupWebInstructionsTitle', 'Información sobre las llaves de acceso en este navegador', 'es'),
  ('authPasskeySetupWebInstructionsBody', 'La disponibilidad de las llaves de acceso en un navegador depende del navegador, el dispositivo y el proveedor donde estén guardadas. Comprueba que el navegador admita llaves de acceso y que haya una disponible en tu gestor de contraseñas. También puedes iniciar sesión con tu nombre de usuario y contraseña.', 'es')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('authPasskeySetupAndroidLoginTitle', 'מפתחות גישה אינם מוגדרים במכשיר Android הזה', 'he'),
  ('authPasskeySetupIosLoginTitle', 'מפתחות גישה אינם מוגדרים ב-iPhone הזה', 'he'),
  ('authPasskeySetupWindowsLoginTitle', 'מפתחות גישה אינם מוגדרים במחשב Windows הזה', 'he'),
  ('authPasskeySetupWebLoginTitle', 'מפתחות גישה אינם מוגדרים בדפדפן הזה', 'he'),
  ('authPasskeySetupPasswordAlternative', 'אפשר להתחבר במקום זאת באמצעות שם המשתמש והסיסמה.', 'he'),
  ('authPasskeySetupMoreInfoButton', 'מידע נוסף', 'he'),
  ('authPasskeySetupWebInstructionsTitle', 'מידע על מפתחות גישה בדפדפן הזה', 'he'),
  ('authPasskeySetupWebInstructionsBody', 'הזמינות של מפתחות גישה בדפדפן תלויה בדפדפן, במכשיר ובספק שבו המפתח נשמר. יש לוודא שהדפדפן תומך במפתחות גישה ושמפתח זמין במנהל הסיסמאות. אפשר גם להתחבר באמצעות שם המשתמש והסיסמה.', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
