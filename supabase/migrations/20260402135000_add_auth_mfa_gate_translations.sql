BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'authMfaLoading', $$Checking your security settings...$$),
    ('es', 'authMfaLoading', $$Comprobando tu configuración de seguridad...$$),
    ('he', 'authMfaLoading', $$בודקים את הגדרות האבטחה שלך...$$),
    ('en', 'authMfaTitle', $$Verify your sign-in$$),
    ('es', 'authMfaTitle', $$Verifica tu inicio de sesión$$),
    ('he', 'authMfaTitle', $$אמת את ההתחברות שלך$$),
    ('en', 'authMfaBody', $$Enter the 6-digit code from your authenticator app to finish signing in.$$),
    ('es', 'authMfaBody', $$Ingresa el código de 6 dígitos de tu aplicación de autenticación para terminar de iniciar sesión.$$),
    ('he', 'authMfaBody', $$הזן את הקוד בן 6 הספרות מאפליקציית האימות שלך כדי להשלים את ההתחברות.$$),
    ('en', 'authMfaLoadFailed', $$We couldn’t load your multi-factor sign-in step. Please try again.$$),
    ('es', 'authMfaLoadFailed', $$No pudimos cargar tu paso de inicio de sesión con múltiples factores. Inténtalo de nuevo.$$),
    ('he', 'authMfaLoadFailed', $$לא הצלחנו לטעון את שלב ההתחברות הרב-שלבי שלך. יש לנסות שוב.$$)
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
