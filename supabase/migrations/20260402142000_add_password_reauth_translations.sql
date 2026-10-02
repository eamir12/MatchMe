BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsPasswordReauthBody', $$For security, send a verification code to your email and enter it before saving your new password.$$),
    ('es', 'settingsPasswordReauthBody', $$Por seguridad, envía un código de verificación a tu correo electrónico e introdúcelo antes de guardar tu nueva contraseña.$$),
    ('he', 'settingsPasswordReauthBody', $$למען האבטחה, שלח קוד אימות לדוא"ל שלך והזן אותו לפני שמירת הסיסמה החדשה שלך.$$),
    ('en', 'settingsPasswordReauthSentGeneric', $$A verification code was sent. Enter it here to continue.$$),
    ('es', 'settingsPasswordReauthSentGeneric', $$Se envió un código de verificación. Introdúcelo aquí para continuar.$$),
    ('he', 'settingsPasswordReauthSentGeneric', $$קוד אימות נשלח. הזן אותו כאן כדי להמשיך.$$)
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
