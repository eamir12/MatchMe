BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'authPasskeyEnterEmail', $$Enter your email to continue with a passkey.$$),
    ('es', 'authPasskeyEnterEmail', $$Ingresa tu correo electrónico para continuar con una clave de acceso.$$),
    ('he', 'authPasskeyEnterEmail', $$הזן את כתובת האימייל שלך כדי להמשיך עם מפתח גישה.$$),
    ('en', 'authPasskeyEnterValidEmail', $$Enter a valid email to continue with a passkey.$$),
    ('es', 'authPasskeyEnterValidEmail', $$Ingresa un correo electrónico válido para continuar con una clave de acceso.$$),
    ('he', 'authPasskeyEnterValidEmail', $$הזן כתובת אימייל תקינה כדי להמשיך עם מפתח גישה.$$)
)
UPDATE translations AS t
SET value = translation_values.value,
    updated_at = now()
FROM translation_values
WHERE t.locale = translation_values.locale
  AND t.key = translation_values.key;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'authPasskeyEnterEmail', $$Enter your email to continue with a passkey.$$),
    ('es', 'authPasskeyEnterEmail', $$Ingresa tu correo electrónico para continuar con una clave de acceso.$$),
    ('he', 'authPasskeyEnterEmail', $$הזן את כתובת האימייל שלך כדי להמשיך עם מפתח גישה.$$),
    ('en', 'authPasskeyEnterValidEmail', $$Enter a valid email to continue with a passkey.$$),
    ('es', 'authPasskeyEnterValidEmail', $$Ingresa un correo electrónico válido para continuar con una clave de acceso.$$),
    ('he', 'authPasskeyEnterValidEmail', $$הזן כתובת אימייל תקינה כדי להמשיך עם מפתח גישה.$$)
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
