BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'authContinueWithPasskey', $$Continue with Passkey$$),
    ('es', 'authContinueWithPasskey', $$Continuar con passkey$$),
    ('he', 'authContinueWithPasskey', $$המשך עם מפתח גישה$$),
    ('en', 'authPasskeyBody', $$Use the passkey saved on this device to sign in securely without a password.$$),
    ('es', 'authPasskeyBody', $$Usa la passkey guardada en este dispositivo para iniciar sesión de forma segura sin contraseña.$$),
    ('he', 'authPasskeyBody', $$השתמש/י במפתח הגישה השמור במכשיר הזה כדי להיכנס בצורה מאובטחת בלי סיסמה.$$),
    ('en', 'authPasskeyUnsupported', $$Passkeys are not available on this platform yet. Use email, password, or another sign-in method instead.$$),
    ('es', 'authPasskeyUnsupported', $$Las passkeys todavía no están disponibles en esta plataforma. Usa el correo, la contraseña u otro método de acceso.$$),
    ('he', 'authPasskeyUnsupported', $$מפתחות גישה עדיין לא זמינים בפלטפורמה הזאת. השתמש/י בדוא״ל, בסיסמה או בדרך כניסה אחרת.$$),
    ('en', 'authPasskeySetupRequired', $$Passkey sign-in is enabled, but it still needs the relying party ID and server URL configured before users can use it.$$),
    ('es', 'authPasskeySetupRequired', $$El inicio de sesión con passkey está habilitado, pero todavía necesita que el ID de relying party y la URL del servidor estén configurados antes de que los usuarios puedan usarlo.$$),
    ('he', 'authPasskeySetupRequired', $$הכניסה עם מפתח גישה מופעלת, אבל עדיין צריך להגדיר את מזהה ה-relying party ואת כתובת השרת לפני שמשתמשים יוכלו להשתמש בה.$$),
    ('en', 'authPasskeyUnavailable', $$Passkey sign-in is not available in this app build yet. It still needs the app-side WebAuthn flow and server verification setup.$$),
    ('es', 'authPasskeyUnavailable', $$El inicio de sesión con passkey todavía no está disponible en esta versión de la app. Aún necesita el flujo WebAuthn del lado de la app y la verificación del servidor.$$),
    ('he', 'authPasskeyUnavailable', $$הכניסה עם מפתח גישה עדיין לא זמינה בגרסה הזאת של האפליקציה. עדיין צריך את זרימת ה-WebAuthn בצד האפליקציה ואת האימות בצד השרת.$$)
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
