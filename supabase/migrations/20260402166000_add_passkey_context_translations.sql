BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsPasskeyAddAnother', $$Add Another Passkey$$),
    ('es', 'settingsPasskeyAddAnother', $$Agregar otra clave de acceso$$),
    ('he', 'settingsPasskeyAddAnother', $$הוסף מפתח גישה נוסף$$),
    ('en', 'settingsPasskeyCurrentSessionPasskey', $$You are already signed in with a passkey on this session.$$),
    ('es', 'settingsPasskeyCurrentSessionPasskey', $$Ya has iniciado sesión con una clave de acceso en esta sesión.$$),
    ('he', 'settingsPasskeyCurrentSessionPasskey', $$כבר התחברת עם מפתח גישה בסשן הזה.$$),
    ('en', 'settingsPasskeyCurrentSessionOther', $$You are signed in with {method}. Add a passkey to make future sign-ins faster and more secure.$$),
    ('es', 'settingsPasskeyCurrentSessionOther', $$Has iniciado sesión con {method}. Agrega una clave de acceso para que los próximos inicios de sesión sean más rápidos y seguros.$$),
    ('he', 'settingsPasskeyCurrentSessionOther', $$התחברת עם {method}. הוסף מפתח גישה כדי שההתחברויות הבאות יהיו מהירות ובטוחות יותר.$$)
)
UPDATE translations AS t
SET value = translation_values.value,
    updated_at = now()
FROM translation_values
WHERE t.locale = translation_values.locale
  AND t.key = translation_values.key;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsPasskeyAddAnother', $$Add Another Passkey$$),
    ('es', 'settingsPasskeyAddAnother', $$Agregar otra clave de acceso$$),
    ('he', 'settingsPasskeyAddAnother', $$הוסף מפתח גישה נוסף$$),
    ('en', 'settingsPasskeyCurrentSessionPasskey', $$You are already signed in with a passkey on this session.$$),
    ('es', 'settingsPasskeyCurrentSessionPasskey', $$Ya has iniciado sesión con una clave de acceso en esta sesión.$$),
    ('he', 'settingsPasskeyCurrentSessionPasskey', $$כבר התחברת עם מפתח גישה בסשן הזה.$$),
    ('en', 'settingsPasskeyCurrentSessionOther', $$You are signed in with {method}. Add a passkey to make future sign-ins faster and more secure.$$),
    ('es', 'settingsPasskeyCurrentSessionOther', $$Has iniciado sesión con {method}. Agrega una clave de acceso para que los próximos inicios de sesión sean más rápidos y seguros.$$),
    ('he', 'settingsPasskeyCurrentSessionOther', $$התחברת עם {method}. הוסף מפתח גישה כדי שההתחברויות הבאות יהיו מהירות ובטוחות יותר.$$)
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
