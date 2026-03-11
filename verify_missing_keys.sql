-- Verify if the missing keys exist in the translations table for 'en', 'es', and 'he'
SELECT locale, key, value 
FROM public.translations 
WHERE key IN (
  'settingsChangePassword', 
  'settingsNewPassword', 
  'settingsConfirmNewPassword', 
  'settingsPasswordMismatch', 
  'settingsPasswordChanged', 
  'settingsPasswordChangeFailed', 
  'settingsDeleteAccount', 
  'settingsDeleteAccountConfirm', 
  'settingsDeleteAccountFailed', 
  'settingsAccountDeleted', 
  'settingsAccountAlreadyDeleted', 
  'paywallSavePercent',
  'settingsGoPremium',
  'settingsUnlockExclusive'
)
ORDER BY key, locale;

-- Also check the total count of keys per locale to see if we are hitting limits
SELECT locale, count(*) as total_keys 
FROM public.translations 
GROUP BY locale;
