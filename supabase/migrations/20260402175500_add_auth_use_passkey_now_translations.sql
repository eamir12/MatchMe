BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'authUsePasskeyNow', $$Use passkey now$$),
    ('es', 'authUsePasskeyNow', $$Usar clave de acceso ahora$$),
    ('he', 'authUsePasskeyNow', $$להשתמש עכשיו במפתח גישה$$)
)
UPDATE translations AS t
SET value = translation_values.value,
    updated_at = now()
FROM translation_values
WHERE t.locale = translation_values.locale
  AND t.key = translation_values.key;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'authUsePasskeyNow', $$Use passkey now$$),
    ('es', 'authUsePasskeyNow', $$Usar clave de acceso ahora$$),
    ('he', 'authUsePasskeyNow', $$להשתמש עכשיו במפתח גישה$$)
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
