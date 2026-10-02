-- Add Passkey Removal Translations to Supabase
-- This script adds translations for the new passkey removal feature
-- Languages: English (en), Spanish (es), Hebrew (he)

-- ============================================================================
-- ENGLISH TRANSLATIONS
-- ============================================================================
INSERT INTO translations (key, locale, value) VALUES
('settingsPasskeyRemove', 'en', 'Remove Passkey'),
('settingsPasskeyRemoveDialogTitle', 'en', 'Remove Passkey?'),
('settingsPasskeyRemoveDialogMessage', 'en', 'This will remove all registered passkeys. You''ll need to sign in with your password or another authentication method.'),
('settingsPasskeyRemoveDialogWarning', 'en', 'This action cannot be undone.'),
('settingsPasskeyRemoveDialogCancel', 'en', 'Keep Passkey'),
('settingsPasskeyRemoveDialogConfirm', 'en', 'Remove All Passkeys'),
('settingsPasskeyRemoved', 'en', 'All passkeys removed successfully'),
('settingsPasskeyRemoveFailed', 'en', 'Failed to remove passkey')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- ============================================================================
-- SPANISH TRANSLATIONS
-- ============================================================================
INSERT INTO translations (key, locale, value) VALUES
('settingsPasskeyRemove', 'es', 'Eliminar Contraseña de Acceso'),
('settingsPasskeyRemoveDialogTitle', 'es', '¿Eliminar Contraseña de Acceso?'),
('settingsPasskeyRemoveDialogMessage', 'es', 'Esto eliminará todas las contraseñas de acceso registradas. Deberá iniciar sesión con su contraseña u otro método de autenticación.'),
('settingsPasskeyRemoveDialogWarning', 'es', 'Esta acción no se puede deshacer.'),
('settingsPasskeyRemoveDialogCancel', 'es', 'Mantener Contraseña de Acceso'),
('settingsPasskeyRemoveDialogConfirm', 'es', 'Eliminar Todas las Contraseñas de Acceso'),
('settingsPasskeyRemoved', 'es', 'Todas las contraseñas de acceso se eliminaron correctamente'),
('settingsPasskeyRemoveFailed', 'es', 'Error al eliminar la contraseña de acceso')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- ============================================================================
-- HEBREW TRANSLATIONS
-- ============================================================================
INSERT INTO translations (key, locale, value) VALUES
('settingsPasskeyRemove', 'he', 'הסר מפתח כניסה'),
('settingsPasskeyRemoveDialogTitle', 'he', 'הסר מפתח כניסה?'),
('settingsPasskeyRemoveDialogMessage', 'he', 'זה יסיר את כל מפתחות הגישה המרושמים. תצטרך להיכנס באמצעות סיסמתך או שיטת אימות אחרת.'),
('settingsPasskeyRemoveDialogWarning', 'he', 'לא ניתן לבטל פעולה זו.'),
('settingsPasskeyRemoveDialogCancel', 'he', 'שמור על מפתח כניסה'),
('settingsPasskeyRemoveDialogConfirm', 'he', 'הסר את כל מפתחות הגישה'),
('settingsPasskeyRemoved', 'he', 'כל מפתחות הגישה הוסרו בהצלחה'),
('settingsPasskeyRemoveFailed', 'he', 'כשל בהסרת מפתח כניסה')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- ============================================================================
-- VERIFICATION QUERIES (Run these to verify the insertions)
-- ============================================================================

-- Check English translations
-- SELECT key, value FROM translations 
-- WHERE locale = 'en' 
-- AND key LIKE 'settingsPasskeyRemove%'
-- ORDER BY key;

-- Check Spanish translations
-- SELECT key, value FROM translations 
-- WHERE locale = 'es' 
-- AND key LIKE 'settingsPasskeyRemove%'
-- ORDER BY key;

-- Check Hebrew translations
-- SELECT key, value FROM translations 
-- WHERE locale = 'he' 
-- AND key LIKE 'settingsPasskeyRemove%'
-- ORDER BY key;

-- Check all three languages together
-- SELECT locale, key, value FROM translations 
-- WHERE key LIKE 'settingsPasskeyRemove%'
-- ORDER BY key, locale;
