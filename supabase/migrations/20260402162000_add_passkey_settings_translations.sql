BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsPasskeyTitle', $$Passkey$$),
    ('es', 'settingsPasskeyTitle', $$Clave de acceso$$),
    ('he', 'settingsPasskeyTitle', $$מפתח גישה$$),
    ('en', 'settingsPasskeyDescription', $$Add a passkey to this account so you can sign in faster and more securely on supported devices.$$),
    ('es', 'settingsPasskeyDescription', $$Agrega una clave de acceso a esta cuenta para iniciar sesión más rápido y de forma más segura en dispositivos compatibles.$$),
    ('he', 'settingsPasskeyDescription', $$הוסף מפתח גישה לחשבון הזה כדי שתוכל להתחבר מהר יותר ובצורה מאובטחת יותר במכשירים נתמכים.$$),
    ('en', 'settingsPasskeyReady', $$Ready to add on this device.$$),
    ('es', 'settingsPasskeyReady', $$Lista para agregar en este dispositivo.$$),
    ('he', 'settingsPasskeyReady', $$מוכן להוספה במכשיר הזה.$$),
    ('en', 'settingsPasskeyAdd', $$Add Passkey$$),
    ('es', 'settingsPasskeyAdd', $$Agregar clave de acceso$$),
    ('he', 'settingsPasskeyAdd', $$הוסף מפתח גישה$$),
    ('en', 'settingsPasskeyAdded', $$Passkey added successfully$$),
    ('es', 'settingsPasskeyAdded', $$La clave de acceso se agregó correctamente$$),
    ('he', 'settingsPasskeyAdded', $$מפתח הגישה נוסף בהצלחה$$),
    ('en', 'settingsPasskeyAddFailed', $$Could not add a passkey right now. Please try again.$$),
    ('es', 'settingsPasskeyAddFailed', $$No se pudo agregar una clave de acceso ahora mismo. Inténtalo de nuevo.$$),
    ('he', 'settingsPasskeyAddFailed', $$לא ניתן להוסיף מפתח גישה כרגע. נסה שוב.$$)
)
UPDATE translations AS t
SET value = translation_values.value,
    updated_at = now()
FROM translation_values
WHERE t.locale = translation_values.locale
  AND t.key = translation_values.key;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsPasskeyTitle', $$Passkey$$),
    ('es', 'settingsPasskeyTitle', $$Clave de acceso$$),
    ('he', 'settingsPasskeyTitle', $$מפתח גישה$$),
    ('en', 'settingsPasskeyDescription', $$Add a passkey to this account so you can sign in faster and more securely on supported devices.$$),
    ('es', 'settingsPasskeyDescription', $$Agrega una clave de acceso a esta cuenta para iniciar sesión más rápido y de forma más segura en dispositivos compatibles.$$),
    ('he', 'settingsPasskeyDescription', $$הוסף מפתח גישה לחשבון הזה כדי שתוכל להתחבר מהר יותר ובצורה מאובטחת יותר במכשירים נתמכים.$$),
    ('en', 'settingsPasskeyReady', $$Ready to add on this device.$$),
    ('es', 'settingsPasskeyReady', $$Lista para agregar en este dispositivo.$$),
    ('he', 'settingsPasskeyReady', $$מוכן להוספה במכשיר הזה.$$),
    ('en', 'settingsPasskeyAdd', $$Add Passkey$$),
    ('es', 'settingsPasskeyAdd', $$Agregar clave de acceso$$),
    ('he', 'settingsPasskeyAdd', $$הוסף מפתח גישה$$),
    ('en', 'settingsPasskeyAdded', $$Passkey added successfully$$),
    ('es', 'settingsPasskeyAdded', $$La clave de acceso se agregó correctamente$$),
    ('he', 'settingsPasskeyAdded', $$מפתח הגישה נוסף בהצלחה$$),
    ('en', 'settingsPasskeyAddFailed', $$Could not add a passkey right now. Please try again.$$),
    ('es', 'settingsPasskeyAddFailed', $$No se pudo agregar una clave de acceso ahora mismo. Inténtalo de nuevo.$$),
    ('he', 'settingsPasskeyAddFailed', $$לא ניתן להוסיף מפתח גישה כרגע. נסה שוב.$$)
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
