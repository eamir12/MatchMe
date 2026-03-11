-- SQL Migration to insert missing Settings Screen translations
-- Languages: English (en), Spanish (es), Hebrew (he)
-- Uses ON CONFLICT to update existing entries

INSERT INTO public.translations (locale, key, value)
VALUES
  -- ENGLISH (en)
  ('en', 'settingsGoPremium', 'Go Premium'),
  ('en', 'settingsUnlockExclusive', 'Unlock exclusive features'),
  ('en', 'settingsChangePassword', 'Change Password'),
  ('en', 'settingsCurrentPassword', 'Current Password'),
  ('en', 'settingsNewPassword', 'New Password'),
  ('en', 'settingsConfirmNewPassword', 'Confirm New Password'),
  ('en', 'settingsPasswordMismatch', 'Passwords do not match'),
  ('en', 'settingsPasswordChanged', 'Password changed successfully'),
  ('en', 'settingsPasswordChangeFailed', 'Failed to change password'),
  ('en', 'settingsDeleteAccount', 'Delete Account'),
  ('en', 'settingsDeleteAccountConfirm', 'Are you sure you want to delete your account? This action cannot be undone.'),
  ('en', 'settingsDeleteAccountFailed', 'Failed to delete account'),
  ('en', 'settingsAccountDeleted', 'Account deleted successfully'),
  ('en', 'settingsAccountAlreadyDeleted', 'Account already deleted'),

  -- SPANISH (es)
  ('es', 'settingsGoPremium', 'Hazte Premium'),
  ('es', 'settingsUnlockExclusive', 'Desbloquea funciones exclusivas'),
  ('es', 'settingsChangePassword', 'Cambiar contraseña'),
  ('es', 'settingsCurrentPassword', 'Contraseña actual'),
  ('es', 'settingsNewPassword', 'Nueva contraseña'),
  ('es', 'settingsConfirmNewPassword', 'Confirmar nueva contraseña'),
  ('es', 'settingsPasswordMismatch', 'Las contraseñas no coinciden'),
  ('es', 'settingsPasswordChanged', 'Contraseña cambiada exitosamente'),
  ('es', 'settingsPasswordChangeFailed', 'Error al cambiar la contraseña'),
  ('es', 'settingsDeleteAccount', 'Eliminar cuenta'),
  ('es', 'settingsDeleteAccountConfirm', '¿Estás seguro de que deseas eliminar tu cuenta? Esta acción no se puede deshacer.'),
  ('es', 'settingsDeleteAccountFailed', 'Error al eliminar la cuenta'),
  ('es', 'settingsAccountDeleted', 'Cuenta eliminada exitosamente'),
  ('es', 'settingsAccountAlreadyDeleted', 'La cuenta ya ha sido eliminada'),

  -- HEBREW (he)
  ('he', 'settingsGoPremium', 'עבור לפרימיום'),
  ('he', 'settingsUnlockExclusive', 'פתח תכונות בלעדיות'),
  ('he', 'settingsChangePassword', 'שנה סיסמה'),
  ('he', 'settingsCurrentPassword', 'סיסמה נוכחית'),
  ('he', 'settingsNewPassword', 'סיסמה חדשה'),
  ('he', 'settingsConfirmNewPassword', 'אמת סיסמה חדשה'),
  ('he', 'settingsPasswordMismatch', 'הסיסמאות אינן תואמות'),
  ('he', 'settingsPasswordChanged', 'הסיסמה שונתה בהצלחה'),
  ('he', 'settingsPasswordChangeFailed', 'נכשל שינוי הסיסמה'),
  ('he', 'settingsDeleteAccount', 'מחק חשבון'),
  ('he', 'settingsDeleteAccountConfirm', 'האם אתה בטוח שברצונך למחוק את החשבון? פעולה זו אינה הפיכה.'),
  ('he', 'settingsDeleteAccountFailed', 'מחיקת החשבון נכשלה'),
  ('he', 'settingsAccountDeleted', 'החשבון נמחק בהצלחה'),
  ('he', 'settingsAccountAlreadyDeleted', 'החשבון כבר נמחק')

ON CONFLICT (locale, key) 
DO UPDATE SET value = EXCLUDED.value, updated_at = now();
