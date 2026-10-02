-- supabase/migrations/20260703000001_update_background_matching_translations.sql
-- Migration: Update translations for Background Matching Mode rename
-- Purpose: Update all translation values after renaming "High Accuracy Mode" to "Background Matching Mode"

BEGIN;

-- English
INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsHighAccuracyMode', 'Background Matching Mode') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsHighAccuracyModeDesc', 'Keep matching even after closing the app. Your location updates periodically in the background so you stay visible to potential matches.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsHighAccuracyModeDesc_android', 'Keep matching even after closing the app. Your location updates periodically in the background so you stay visible to potential matches.
• Requires a persistent notification so the system keeps the app running.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsHighAccuracyModeDesc_ios', 'Keep matching even after closing the app. Your location updates periodically in the background so you stay visible to potential matches.
• Updates approximately every ~10 minutes of movement (uses more battery).') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsHighAccuracyModeDesc_web', 'Background matching is not supported on web. Matching only works while the app is open.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish
INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsHighAccuracyMode', 'Modo de Coincidencia en Segundo Plano') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsHighAccuracyModeDesc', 'Sigue coincidiendo incluso después de cerrar la app. Tu ubicación se actualiza periódicamente en segundo plano para que sigas siendo visible para posibles coincidencias.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsHighAccuracyModeDesc_android', 'Sigue coincidiendo incluso después de cerrar la app. Tu ubicación se actualiza periódicamente en segundo plano para que sigas siendo visible para posibles coincidencias.
• Requiere una notificación persistente para que el sistema mantenga la app en ejecución.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsHighAccuracyModeDesc_ios', 'Sigue coincidiendo incluso después de cerrar la app. Tu ubicación se actualiza periódicamente en segundo plano para que sigas siendo visible para posibles coincidencias.
• Se actualiza aproximadamente cada ~10 minutos de movimiento (usa más batería).') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsHighAccuracyModeDesc_web', 'La coincidencia en segundo plano no está disponible en web. Solo funciona mientras la app está abierta.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew
INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsHighAccuracyMode', 'מצב התאמה ברקע') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsHighAccuracyModeDesc', 'המשך להתאים גם לאחר סגירת האפליקציה. המיקום שלך מתעדכן מעת לעת ברקע כך שתישאר גלוי להתאמות פוטנציאליות.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsHighAccuracyModeDesc_android', 'המשך להתאים גם לאחר סגירת האפליקציה. המיקום שלך מתעדכן מעת לעת ברקע כך שתישאר גלוי להתאמות פוטנציאליות.
• דורש התראה קבועה כדי שהמערכת תשמור על האפליקציה פועלת.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsHighAccuracyModeDesc_ios', 'המשך להתאים גם לאחר סגירת האפליקציה. המיקום שלך מתעדכן מעת לעת ברקע כך שתישאר גלוי להתאמות פוטנציאליות.
• מתעדכן בערך כל ~10 דקות של תנועה (צורך יותר סוללה).') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsHighAccuracyModeDesc_web', 'התאמה ברקע אינה נתמכת בדפדפן. ההתאמה פועלת רק כשהאפליקציה פתוחה.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
