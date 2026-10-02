BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'authPasskeyReadyForEmail', $$Use the passkey saved for {email} on this device.$$),
    ('es', 'authPasskeyReadyForEmail', $$Usa la clave de acceso guardada para {email} en este dispositivo.$$),
    ('he', 'authPasskeyReadyForEmail', $$השתמש/י במפתח הגישה השמור עבור {email} במכשיר הזה.$$),
    ('en', 'authPasskeyNoPasswordNeeded', $$No password needed on supported devices.$$),
    ('es', 'authPasskeyNoPasswordNeeded', $$No se necesita contraseña en dispositivos compatibles.$$),
    ('he', 'authPasskeyNoPasswordNeeded', $$אין צורך בסיסמה במכשירים נתמכים.$$)
)
UPDATE translations AS t
SET value = translation_values.value,
    updated_at = now()
FROM translation_values
WHERE t.locale = translation_values.locale
  AND t.key = translation_values.key;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'authPasskeyReadyForEmail', $$Use the passkey saved for {email} on this device.$$),
    ('es', 'authPasskeyReadyForEmail', $$Usa la clave de acceso guardada para {email} en este dispositivo.$$),
    ('he', 'authPasskeyReadyForEmail', $$השתמש/י במפתח הגישה השמור עבור {email} במכשיר הזה.$$),
    ('en', 'authPasskeyNoPasswordNeeded', $$No password needed on supported devices.$$),
    ('es', 'authPasskeyNoPasswordNeeded', $$No se necesita contraseña en dispositivos compatibles.$$),
    ('he', 'authPasskeyNoPasswordNeeded', $$אין צורך בסיסמה במכשירים נתמכים.$$)
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
