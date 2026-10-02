BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsPasskeyStatusReady', $$Ready on this device$$),
    ('es', 'settingsPasskeyStatusReady', $$Lista en este dispositivo$$),
    ('he', 'settingsPasskeyStatusReady', $$מוכן במכשיר הזה$$),
    ('en', 'settingsPasskeyStatusUnsupported', $$Not supported on this device$$),
    ('es', 'settingsPasskeyStatusUnsupported', $$No es compatible con este dispositivo$$),
    ('he', 'settingsPasskeyStatusUnsupported', $$לא נתמך במכשיר הזה$$),
    ('en', 'settingsPasskeyStatusSetupRequired', $$Needs server setup$$),
    ('es', 'settingsPasskeyStatusSetupRequired', $$Necesita configuración del servidor$$),
    ('he', 'settingsPasskeyStatusSetupRequired', $$נדרשת הגדרת שרת$$),
    ('en', 'settingsPasskeyStatusCurrentSession', $$Current session: {method}$$),
    ('es', 'settingsPasskeyStatusCurrentSession', $$Sesión actual: {method}$$),
    ('he', 'settingsPasskeyStatusCurrentSession', $$הסשן הנוכחי: {method}$$)
)
UPDATE translations AS t
SET value = translation_values.value,
    updated_at = now()
FROM translation_values
WHERE t.locale = translation_values.locale
  AND t.key = translation_values.key;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsPasskeyStatusReady', $$Ready on this device$$),
    ('es', 'settingsPasskeyStatusReady', $$Lista en este dispositivo$$),
    ('he', 'settingsPasskeyStatusReady', $$מוכן במכשיר הזה$$),
    ('en', 'settingsPasskeyStatusUnsupported', $$Not supported on this device$$),
    ('es', 'settingsPasskeyStatusUnsupported', $$No es compatible con este dispositivo$$),
    ('he', 'settingsPasskeyStatusUnsupported', $$לא נתמך במכשיר הזה$$),
    ('en', 'settingsPasskeyStatusSetupRequired', $$Needs server setup$$),
    ('es', 'settingsPasskeyStatusSetupRequired', $$Necesita configuración del servidor$$),
    ('he', 'settingsPasskeyStatusSetupRequired', $$נדרשת הגדרת שרת$$),
    ('en', 'settingsPasskeyStatusCurrentSession', $$Current session: {method}$$),
    ('es', 'settingsPasskeyStatusCurrentSession', $$Sesión actual: {method}$$),
    ('he', 'settingsPasskeyStatusCurrentSession', $$הסשן הנוכחי: {method}$$)
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
