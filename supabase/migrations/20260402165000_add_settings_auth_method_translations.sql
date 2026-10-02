BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsCurrentSignInMethodTitle', $$Current sign-in method$$),
    ('es', 'settingsCurrentSignInMethodTitle', $$Método de inicio de sesión actual$$),
    ('he', 'settingsCurrentSignInMethodTitle', $$שיטת ההתחברות הנוכחית$$),
    ('en', 'settingsCurrentSignInMethodDescription', $$This shows how your current session was authenticated.$$),
    ('es', 'settingsCurrentSignInMethodDescription', $$Esto muestra cómo se autenticó tu sesión actual.$$),
    ('he', 'settingsCurrentSignInMethodDescription', $$זה מציג איך הסשן הנוכחי שלך אומת.$$),
    ('en', 'settingsAuthMethodPasskey', $$Passkey$$),
    ('es', 'settingsAuthMethodPasskey', $$Clave de acceso$$),
    ('he', 'settingsAuthMethodPasskey', $$מפתח גישה$$),
    ('en', 'settingsAuthMethodPassword', $$Password$$),
    ('es', 'settingsAuthMethodPassword', $$Contraseña$$),
    ('he', 'settingsAuthMethodPassword', $$סיסמה$$),
    ('en', 'settingsAuthMethodEmailOtp', $$Email code$$),
    ('es', 'settingsAuthMethodEmailOtp', $$Código por correo$$),
    ('he', 'settingsAuthMethodEmailOtp', $$קוד בדוא״ל$$),
    ('en', 'settingsAuthMethodSmsOtp', $$SMS code$$),
    ('es', 'settingsAuthMethodSmsOtp', $$Código SMS$$),
    ('he', 'settingsAuthMethodSmsOtp', $$קוד SMS$$),
    ('en', 'settingsAuthMethodGoogle', $$Google$$),
    ('es', 'settingsAuthMethodGoogle', $$Google$$),
    ('he', 'settingsAuthMethodGoogle', $$Google$$),
    ('en', 'settingsAuthMethodMicrosoft', $$Microsoft$$),
    ('es', 'settingsAuthMethodMicrosoft', $$Microsoft$$),
    ('he', 'settingsAuthMethodMicrosoft', $$Microsoft$$),
    ('en', 'settingsAuthMethodApple', $$Apple$$),
    ('es', 'settingsAuthMethodApple', $$Apple$$),
    ('he', 'settingsAuthMethodApple', $$Apple$$),
    ('en', 'settingsAuthMethodFacebook', $$Facebook$$),
    ('es', 'settingsAuthMethodFacebook', $$Facebook$$),
    ('he', 'settingsAuthMethodFacebook', $$Facebook$$),
    ('en', 'settingsAuthMethodUnknown', $$Unknown$$),
    ('es', 'settingsAuthMethodUnknown', $$Desconocido$$),
    ('he', 'settingsAuthMethodUnknown', $$לא ידוע$$)
)
UPDATE translations AS t
SET value = translation_values.value,
    updated_at = now()
FROM translation_values
WHERE t.locale = translation_values.locale
  AND t.key = translation_values.key;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsCurrentSignInMethodTitle', $$Current sign-in method$$),
    ('es', 'settingsCurrentSignInMethodTitle', $$Método de inicio de sesión actual$$),
    ('he', 'settingsCurrentSignInMethodTitle', $$שיטת ההתחברות הנוכחית$$),
    ('en', 'settingsCurrentSignInMethodDescription', $$This shows how your current session was authenticated.$$),
    ('es', 'settingsCurrentSignInMethodDescription', $$Esto muestra cómo se autenticó tu sesión actual.$$),
    ('he', 'settingsCurrentSignInMethodDescription', $$זה מציג איך הסשן הנוכחי שלך אומת.$$),
    ('en', 'settingsAuthMethodPasskey', $$Passkey$$),
    ('es', 'settingsAuthMethodPasskey', $$Clave de acceso$$),
    ('he', 'settingsAuthMethodPasskey', $$מפתח גישה$$),
    ('en', 'settingsAuthMethodPassword', $$Password$$),
    ('es', 'settingsAuthMethodPassword', $$Contraseña$$),
    ('he', 'settingsAuthMethodPassword', $$סיסמה$$),
    ('en', 'settingsAuthMethodEmailOtp', $$Email code$$),
    ('es', 'settingsAuthMethodEmailOtp', $$Código por correo$$),
    ('he', 'settingsAuthMethodEmailOtp', $$קוד בדוא״ל$$),
    ('en', 'settingsAuthMethodSmsOtp', $$SMS code$$),
    ('es', 'settingsAuthMethodSmsOtp', $$Código SMS$$),
    ('he', 'settingsAuthMethodSmsOtp', $$קוד SMS$$),
    ('en', 'settingsAuthMethodGoogle', $$Google$$),
    ('es', 'settingsAuthMethodGoogle', $$Google$$),
    ('he', 'settingsAuthMethodGoogle', $$Google$$),
    ('en', 'settingsAuthMethodMicrosoft', $$Microsoft$$),
    ('es', 'settingsAuthMethodMicrosoft', $$Microsoft$$),
    ('he', 'settingsAuthMethodMicrosoft', $$Microsoft$$),
    ('en', 'settingsAuthMethodApple', $$Apple$$),
    ('es', 'settingsAuthMethodApple', $$Apple$$),
    ('he', 'settingsAuthMethodApple', $$Apple$$),
    ('en', 'settingsAuthMethodFacebook', $$Facebook$$),
    ('es', 'settingsAuthMethodFacebook', $$Facebook$$),
    ('he', 'settingsAuthMethodFacebook', $$Facebook$$),
    ('en', 'settingsAuthMethodUnknown', $$Unknown$$),
    ('es', 'settingsAuthMethodUnknown', $$Desconocido$$),
    ('he', 'settingsAuthMethodUnknown', $$לא ידוע$$)
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
