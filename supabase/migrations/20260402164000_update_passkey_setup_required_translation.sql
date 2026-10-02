BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'authPasskeySetupRequired', $$Passkeys are enabled, but the relying party ID and server URL still need to be configured before people can use them.$$),
    ('es', 'authPasskeySetupRequired', $$Las passkeys están habilitadas, pero todavía es necesario configurar el ID de relying party y la URL del servidor antes de que las personas puedan usarlas.$$),
    ('he', 'authPasskeySetupRequired', $$מפתחות גישה מופעלים, אבל עדיין צריך להגדיר את מזהה ה-relying party ואת כתובת השרת לפני שאנשים יוכלו להשתמש בהם.$$)
)
UPDATE translations AS t
SET value = translation_values.value,
    updated_at = now()
FROM translation_values
WHERE t.locale = translation_values.locale
  AND t.key = translation_values.key;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'authPasskeySetupRequired', $$Passkeys are enabled, but the relying party ID and server URL still need to be configured before people can use them.$$),
    ('es', 'authPasskeySetupRequired', $$Las passkeys están habilitadas, pero todavía es necesario configurar el ID de relying party y la URL del servidor antes de que las personas puedan usarlas.$$),
    ('he', 'authPasskeySetupRequired', $$מפתחות גישה מופעלים, אבל עדיין צריך להגדיר את מזהה ה-relying party ואת כתובת השרת לפני שאנשים יוכלו להשתמש בהם.$$)
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
