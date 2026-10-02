BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsPasskeyStatusAddedThisSession', $$Added in this session$$),
    ('es', 'settingsPasskeyStatusAddedThisSession', $$Agregada en esta sesión$$),
    ('he', 'settingsPasskeyStatusAddedThisSession', $$נוסף בסשן הזה$$),
    ('en', 'settingsPasskeyAddedForFutureSignIn', $$Passkey added. You can use it the next time you sign in.$$),
    ('es', 'settingsPasskeyAddedForFutureSignIn', $$Clave de acceso agregada. Puedes usarla la próxima vez que inicies sesión.$$),
    ('he', 'settingsPasskeyAddedForFutureSignIn', $$מפתח הגישה נוסף. אפשר להשתמש בו בפעם הבאה שתתחבר/י.$$)
)
UPDATE translations AS t
SET value = translation_values.value,
    updated_at = now()
FROM translation_values
WHERE t.locale = translation_values.locale
  AND t.key = translation_values.key;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsPasskeyStatusAddedThisSession', $$Added in this session$$),
    ('es', 'settingsPasskeyStatusAddedThisSession', $$Agregada en esta sesión$$),
    ('he', 'settingsPasskeyStatusAddedThisSession', $$נוסף בסשן הזה$$),
    ('en', 'settingsPasskeyAddedForFutureSignIn', $$Passkey added. You can use it the next time you sign in.$$),
    ('es', 'settingsPasskeyAddedForFutureSignIn', $$Clave de acceso agregada. Puedes usarla la próxima vez que inicies sesión.$$),
    ('he', 'settingsPasskeyAddedForFutureSignIn', $$מפתח הגישה נוסף. אפשר להשתמש בו בפעם הבאה שתתחבר/י.$$)
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
