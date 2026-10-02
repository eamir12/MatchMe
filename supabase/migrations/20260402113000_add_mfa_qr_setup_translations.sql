BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsMfaSetupBody', $$Open your authenticator app, scan the QR code or enter the setup key, then enter the 6-digit code it generates.$$),
    ('es', 'settingsMfaSetupBody', $$Abre tu aplicación de autenticación, escanea el código QR o ingresa la clave de configuración y luego introduce el código de 6 dígitos que genere.$$),
    ('he', 'settingsMfaSetupBody', $$פתח את אפליקציית האימות שלך, סרוק את קוד ה-QR או הזן את מפתח ההגדרה, ואז הזן את הקוד בן 6 הספרות שהיא מייצרת.$$),
    ('en', 'settingsMfaOpenAuthenticator', $$Open authenticator app$$),
    ('es', 'settingsMfaOpenAuthenticator', $$Abrir aplicación de autenticación$$),
    ('he', 'settingsMfaOpenAuthenticator', $$פתח אפליקציית אימות$$),
    ('en', 'settingsMfaOpenAuthenticatorBody', $$On this device, we can try to hand off setup directly to a compatible authenticator app.$$),
    ('es', 'settingsMfaOpenAuthenticatorBody', $$En este dispositivo, podemos intentar transferir la configuración directamente a una aplicación de autenticación compatible.$$),
    ('he', 'settingsMfaOpenAuthenticatorBody', $$במכשיר הזה אפשר לנסות להעביר את ההגדרה ישירות לאפליקציית אימות תואמת.$$),
    ('en', 'settingsMfaOpenAuthenticatorFailed', $$Could not open an authenticator app. Use the QR code or setup key below instead.$$),
    ('es', 'settingsMfaOpenAuthenticatorFailed', $$No se pudo abrir una aplicación de autenticación. Usa el código QR o la clave de configuración de abajo.$$),
    ('he', 'settingsMfaOpenAuthenticatorFailed', $$לא הצלחנו לפתוח אפליקציית אימות. במקום זאת אפשר להשתמש בקוד ה-QR או במפתח ההגדרה שמופיעים למטה.$$),
    ('en', 'settingsMfaQrTitle', $$Scan QR code$$),
    ('es', 'settingsMfaQrTitle', $$Escanear código QR$$),
    ('he', 'settingsMfaQrTitle', $$סרוק קוד QR$$),
    ('en', 'settingsMfaQrBody', $$Best when your authenticator app is on another device.$$),
    ('es', 'settingsMfaQrBody', $$Es lo mejor cuando tu aplicación de autenticación está en otro dispositivo.$$),
    ('he', 'settingsMfaQrBody', $$האפשרות הטובה ביותר כשהאפליקציה לאימות נמצאת במכשיר אחר.$$),
    ('en', 'settingsMfaManualEntryTitle', $$Or enter the setup key manually$$),
    ('es', 'settingsMfaManualEntryTitle', $$O ingresa la clave de configuración manualmente$$),
    ('he', 'settingsMfaManualEntryTitle', $$או הזן את מפתח ההגדרה ידנית$$),
    ('en', 'settingsMfaManualEntryBody', $$If scanning is not available, choose manual setup in your authenticator app and paste this key.$$),
    ('es', 'settingsMfaManualEntryBody', $$Si no puedes escanear, elige la configuración manual en tu aplicación de autenticación y pega esta clave.$$),
    ('he', 'settingsMfaManualEntryBody', $$אם לא ניתן לסרוק, בחר בהגדרה ידנית באפליקציית האימות שלך והדבק את המפתח הזה.$$)
)
UPDATE translations AS t
SET value = translation_values.value,
    updated_at = now()
FROM translation_values
WHERE t.locale = translation_values.locale
  AND t.key = translation_values.key;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'settingsMfaSetupBody', $$Open your authenticator app, scan the QR code or enter the setup key, then enter the 6-digit code it generates.$$),
    ('es', 'settingsMfaSetupBody', $$Abre tu aplicación de autenticación, escanea el código QR o ingresa la clave de configuración y luego introduce el código de 6 dígitos que genere.$$),
    ('he', 'settingsMfaSetupBody', $$פתח את אפליקציית האימות שלך, סרוק את קוד ה-QR או הזן את מפתח ההגדרה, ואז הזן את הקוד בן 6 הספרות שהיא מייצרת.$$),
    ('en', 'settingsMfaOpenAuthenticator', $$Open authenticator app$$),
    ('es', 'settingsMfaOpenAuthenticator', $$Abrir aplicación de autenticación$$),
    ('he', 'settingsMfaOpenAuthenticator', $$פתח אפליקציית אימות$$),
    ('en', 'settingsMfaOpenAuthenticatorBody', $$On this device, we can try to hand off setup directly to a compatible authenticator app.$$),
    ('es', 'settingsMfaOpenAuthenticatorBody', $$En este dispositivo, podemos intentar transferir la configuración directamente a una aplicación de autenticación compatible.$$),
    ('he', 'settingsMfaOpenAuthenticatorBody', $$במכשיר הזה אפשר לנסות להעביר את ההגדרה ישירות לאפליקציית אימות תואמת.$$),
    ('en', 'settingsMfaOpenAuthenticatorFailed', $$Could not open an authenticator app. Use the QR code or setup key below instead.$$),
    ('es', 'settingsMfaOpenAuthenticatorFailed', $$No se pudo abrir una aplicación de autenticación. Usa el código QR o la clave de configuración de abajo.$$),
    ('he', 'settingsMfaOpenAuthenticatorFailed', $$לא הצלחנו לפתוח אפליקציית אימות. במקום זאת אפשר להשתמש בקוד ה-QR או במפתח ההגדרה שמופיעים למטה.$$),
    ('en', 'settingsMfaQrTitle', $$Scan QR code$$),
    ('es', 'settingsMfaQrTitle', $$Escanear código QR$$),
    ('he', 'settingsMfaQrTitle', $$סרוק קוד QR$$),
    ('en', 'settingsMfaQrBody', $$Best when your authenticator app is on another device.$$),
    ('es', 'settingsMfaQrBody', $$Es lo mejor cuando tu aplicación de autenticación está en otro dispositivo.$$),
    ('he', 'settingsMfaQrBody', $$האפשרות הטובה ביותר כשהאפליקציה לאימות נמצאת במכשיר אחר.$$),
    ('en', 'settingsMfaManualEntryTitle', $$Or enter the setup key manually$$),
    ('es', 'settingsMfaManualEntryTitle', $$O ingresa la clave de configuración manualmente$$),
    ('he', 'settingsMfaManualEntryTitle', $$או הזן את מפתח ההגדרה ידנית$$),
    ('en', 'settingsMfaManualEntryBody', $$If scanning is not available, choose manual setup in your authenticator app and paste this key.$$),
    ('es', 'settingsMfaManualEntryBody', $$Si no puedes escanear, elige la configuración manual en tu aplicación de autenticación y pega esta clave.$$),
    ('he', 'settingsMfaManualEntryBody', $$אם לא ניתן לסרוק, בחר בהגדרה ידנית באפליקציית האימות שלך והדבק את המפתח הזה.$$)
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
