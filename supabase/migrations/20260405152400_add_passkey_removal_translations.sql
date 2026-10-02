-- Add passkey removal translations for English, Spanish, and Hebrew
-- Run this migration to add the required translation keys to the translations table

BEGIN;

-- English translations
INSERT INTO translations (key, locale, value)
VALUES 
  ('settingsPasskeyRevoke', 'en', 'Delete all passkeys'),
  ('settingsPasskeyRevokeConfirm', 'en', 'Are you sure you want to delete all your passkeys? You will need to use another sign-in method.'),
  ('settingsPasskeyRevoked', 'en', 'All passkeys deleted successfully'),
  ('settingsPasskeyRevokeFailed', 'en', 'Failed to delete passkeys. Please try again.')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (key, locale, value)
VALUES 
  ('settingsPasskeyRevoke', 'es', 'Eliminar todas las claves de acceso'),
  ('settingsPasskeyRevokeConfirm', 'es', '¿Está seguro de que desea eliminar todas sus claves de acceso? Tendrá que utilizar otro método de inicio de sesión.'),
  ('settingsPasskeyRevoked', 'es', 'Todas las claves de acceso eliminadas correctamente'),
  ('settingsPasskeyRevokeFailed', 'es', 'Error al eliminar las claves de acceso. Inténtelo de nuevo.')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (key, locale, value)
VALUES 
  ('settingsPasskeyRevoke', 'he', 'מחק את כל מפתחות הגישה'),
  ('settingsPasskeyRevokeConfirm', 'he', 'האם אתה בטוח שברצונך למחוק את כל מפתחות הגישה שלך? תצטרך להשתמש בשיטת כניסה אחרת.'),
  ('settingsPasskeyRevoked', 'he', 'כל מפתחות הגישה נמחקו בהצלחה'),
  ('settingsPasskeyRevokeFailed', 'he', 'נכשל במחיקת מפתחות הגישה. נסה שוב.')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

COMMIT;