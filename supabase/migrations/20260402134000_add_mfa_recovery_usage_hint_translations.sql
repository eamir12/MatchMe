BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsMfaRecoveryCodesUsageHint', $$If you lose access to your authenticator app, start a protected action and choose "Use recovery code instead" in the verification dialog.$$),
    ('es', 'settingsMfaRecoveryCodesUsageHint', $$Si pierdes acceso a tu aplicación de autenticación, inicia una acción protegida y elige "Usar código de recuperación" en el diálogo de verificación.$$),
    ('he', 'settingsMfaRecoveryCodesUsageHint', $$אם מאבדים גישה לאפליקציית האימות, מתחילים פעולה מוגנת ובוחרים "השתמש בקוד שחזור במקום" בחלון האימות.$$),
    ('en', 'settingsMfaRecoveryCodesAndEmailUsageHint', $$If you lose access to your authenticator app, start a protected action and choose "Use recovery code instead" or "Use email code instead" in the verification dialog.$$),
    ('es', 'settingsMfaRecoveryCodesAndEmailUsageHint', $$Si pierdes acceso a tu aplicación de autenticación, inicia una acción protegida y elige "Usar código de recuperación" o "Usar código por correo" en el diálogo de verificación.$$),
    ('he', 'settingsMfaRecoveryCodesAndEmailUsageHint', $$אם מאבדים גישה לאפליקציית האימות, מתחילים פעולה מוגנת ובוחרים "השתמש בקוד שחזור במקום" או "השתמש בקוד שנשלח בדוא״ל במקום" בחלון האימות.$$)
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
