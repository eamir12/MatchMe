BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'authPasskeyInlineHintTitle', $$Already using passkeys for this email?$$),
    ('es', 'authPasskeyInlineHintTitle', $$¿Ya usas claves de acceso para este correo?$$),
    ('he', 'authPasskeyInlineHintTitle', $$כבר משתמש/ת במפתחות גישה עבור האימייל הזה?$$),
    ('en', 'authPasskeyInlineHintBody', $$You can skip the password field and use the passkey button below.$$),
    ('es', 'authPasskeyInlineHintBody', $$Puedes omitir el campo de contraseña y usar el botón de clave de acceso de abajo.$$),
    ('he', 'authPasskeyInlineHintBody', $$אפשר לדלג על שדה הסיסמה ולהשתמש בכפתור מפתח הגישה למטה.$$)
)
UPDATE translations AS t
SET value = translation_values.value,
    updated_at = now()
FROM translation_values
WHERE t.locale = translation_values.locale
  AND t.key = translation_values.key;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'authPasskeyInlineHintTitle', $$Already using passkeys for this email?$$),
    ('es', 'authPasskeyInlineHintTitle', $$¿Ya usas claves de acceso para este correo?$$),
    ('he', 'authPasskeyInlineHintTitle', $$כבר משתמש/ת במפתחות גישה עבור האימייל הזה?$$),
    ('en', 'authPasskeyInlineHintBody', $$You can skip the password field and use the passkey button below.$$),
    ('es', 'authPasskeyInlineHintBody', $$Puedes omitir el campo de contraseña y usar el botón de clave de acceso de abajo.$$),
    ('he', 'authPasskeyInlineHintBody', $$אפשר לדלג על שדה הסיסמה ולהשתמש בכפתור מפתח הגישה למטה.$$)
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
