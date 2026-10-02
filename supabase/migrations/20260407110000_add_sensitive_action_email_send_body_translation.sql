BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsMfaEmailCodeSendBody', $$We'll email you a 6-digit verification code to continue.$$),
    ('es', 'settingsMfaEmailCodeSendBody', $$Te enviaremos un código de verificación de 6 dígitos para continuar.$$),
    ('he', 'settingsMfaEmailCodeSendBody', $$נשלח אליך קוד אימות בן 6 ספרות כדי להמשיך.$$)
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
