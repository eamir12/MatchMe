-- Insert translations for the new Import from Online Providers multi-account screen
-- Run this in Supabase SQL editor to add the necessary translation keys
-- Note: The translations table uses 'locale' field, not 'language'

-- Online Providers Screen Translations

-- onlineProvidersAddAccount - For the add account dialog
-- Fallback in code: 'Add Account'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'onlineProvidersAddAccount', 'Add Account', NOW(), NOW()),
  ('es', 'onlineProvidersAddAccount', 'Agregar Cuenta', NOW(), NOW()),
  ('he', 'onlineProvidersAddAccount', 'הוסף חשבון', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

-- onlineProvidersRemoveAccount - For the remove account dialog
-- Fallback in code: 'Remove Account'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'onlineProvidersRemoveAccount', 'Remove Account', NOW(), NOW()),
  ('es', 'onlineProvidersRemoveAccount', 'Eliminar Cuenta', NOW(), NOW()),
  ('he', 'onlineProvidersRemoveAccount', 'הסר חשבון', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

-- onlineProvidersRemoveAccountConfirm - Confirmation message for removing account
-- Fallback in code: 'Are you sure you want to remove'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'onlineProvidersRemoveAccountConfirm', 'Are you sure you want to remove {account}?', NOW(), NOW()),
  ('es', 'onlineProvidersRemoveAccountConfirm', '¿Seguro que quieres eliminar {account}?', NOW(), NOW()),
  ('he', 'onlineProvidersRemoveAccountConfirm', 'האם אתה בטוח שברצונך להסיר את {account}?', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE
SET value = EXCLUDED.value, updated_at = NOW();

-- onlineProvidersNoAccounts - Empty state when no accounts connected
-- Fallback in code: 'No accounts connected'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'onlineProvidersNoAccounts', 'No accounts connected', NOW(), NOW()),
  ('es', 'onlineProvidersNoAccounts', 'No hay cuentas conectadas', NOW(), NOW()),
  ('he', 'onlineProvidersNoAccounts', 'אין חשבונות מחוברים', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

-- onlineProvidersAddAccountHint - Hint text for adding accounts
-- Fallback in code: 'Tap the + button to add an account and import calendar events from Google, Outlook, or Apple.'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'onlineProvidersAddAccountHint', 'Tap the + button to add an account and import calendar events from Google, Outlook, or Apple.', NOW(), NOW()),
  ('es', 'onlineProvidersAddAccountHint', 'Toca el botón + para agregar una cuenta e importar eventos de calendario de Google, Outlook o Apple.', NOW(), NOW()),
  ('he', 'onlineProvidersAddAccountHint', 'הקש על כפתור ה-+ כדי להוסיף חשבון ולייבא אירועי יומן מגוגל, אאוטלוק או אפל.', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

-- onlineProvidersNoEvents - When no events found in accounts
-- Fallback in code: 'No events found'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'onlineProvidersNoEvents', 'No events found', NOW(), NOW()),
  ('es', 'onlineProvidersNoEvents', 'No se encontraron eventos', NOW(), NOW()),
  ('he', 'onlineProvidersNoEvents', 'לא נמצאו אירועים', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

-- onlineProvidersEvents - Label for event count
-- Fallback in code: 'events'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'onlineProvidersEvents', 'events', NOW(), NOW()),
  ('es', 'onlineProvidersEvents', 'eventos', NOW(), NOW()),
  ('he', 'onlineProvidersEvents', 'אירועים', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

-- Legacy CalendarSync translations (keeping for compatibility)

-- CalendarSyncConnectedAccounts - Header for connected accounts section
-- Fallback in code: 'Connected Accounts'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'calendarSyncConnectedAccounts', 'Connected Accounts', NOW(), NOW()),
  ('es', 'calendarSyncConnectedAccounts', 'Cuentas Conectadas', NOW(), NOW()),
  ('he', 'calendarSyncConnectedAccounts', 'חשבונות מחוברים', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

-- CalendarSyncNoAccounts - Empty state when no accounts connected
-- Fallback in code: 'No accounts connected'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'calendarSyncNoAccounts', 'No accounts connected', NOW(), NOW()),
  ('es', 'calendarSyncNoAccounts', 'No hay cuentas conectadas', NOW(), NOW()),
  ('he', 'calendarSyncNoAccounts', 'אין חשבונות מחוברים', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

-- CalendarSyncAddAccountHint - Hint text for adding accounts
-- Fallback in code: 'Add an account to import calendar events from Google, Outlook, or Apple.'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'calendarSyncAddAccountHint', 'Add an account to import calendar events from Google, Outlook, or Apple.', NOW(), NOW()),
  ('es', 'calendarSyncAddAccountHint', 'Agrega una cuenta para importar eventos de calendario de Google, Outlook o Apple.', NOW(), NOW()),
  ('he', 'calendarSyncAddAccountHint', 'הוסף חשבון לייבוא אירועי יומן מגוגל, אאוטלוק או אפל.', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

-- CalendarSyncNoEvents - When no events found in accounts
-- Fallback in code: 'No events found'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'calendarSyncNoEvents', 'No events found', NOW(), NOW()),
  ('es', 'calendarSyncNoEvents', 'No se encontraron eventos', NOW(), NOW()),
  ('he', 'calendarSyncNoEvents', 'לא נמצאו אירועים', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

-- CalendarSyncNoEventsHint - Hint for selecting calendars
-- Fallback in code: 'Select calendars from your accounts to import events.'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'calendarSyncNoEventsHint', 'Select calendars from your accounts to import events.', NOW(), NOW()),
  ('es', 'calendarSyncNoEventsHint', 'Selecciona calendarios de tus cuentas para importar eventos.', NOW(), NOW()),
  ('he', 'calendarSyncNoEventsHint', 'בחר יומנים מהחשבונות שלך לייבוא אירועים.', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

-- CalendarSyncSelectProvider - For the provider selection dialog
-- Fallback in code: 'Select Provider'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'calendarSyncSelectProvider', 'Select Provider', NOW(), NOW()),
  ('es', 'calendarSyncSelectProvider', 'Seleccionar Proveedor', NOW(), NOW()),
  ('he', 'calendarSyncSelectProvider', 'בחר ספק', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

-- CalendarSyncAddAccount - For the add account button
-- Fallback in code: 'Add Account'
INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES 
  ('en', 'calendarSyncAddAccount', 'Add Account', NOW(), NOW()),
  ('es', 'calendarSyncAddAccount', 'Agregar Cuenta', NOW(), NOW()),
  ('he', 'calendarSyncAddAccount', 'הוסף חשבון', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersAccountRefreshFailed', 'Could not refresh {account}. Please try again.', NOW(), NOW()),
  ('es', 'onlineProvidersAccountRefreshFailed', 'No se pudo actualizar {account}. Inténtalo de nuevo.', NOW(), NOW()),
  ('he', 'onlineProvidersAccountRefreshFailed', 'לא ניתן היה לרענן את {account}. נסה שוב.', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersReconnectRequired', 'Reconnect this account to continue importing events.', NOW(), NOW()),
  ('es', 'onlineProvidersReconnectRequired', 'Vuelve a conectar esta cuenta para seguir importando eventos.', NOW(), NOW()),
  ('he', 'onlineProvidersReconnectRequired', 'חבר מחדש את החשבון הזה כדי להמשיך לייבא אירועים.', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersAvailableAccount', 'Available account', NOW(), NOW()),
  ('es', 'onlineProvidersAvailableAccount', 'Cuenta disponible', NOW(), NOW()),
  ('he', 'onlineProvidersAvailableAccount', 'חשבון זמין', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersUseAnotherAccount', 'Use another {provider} account', NOW(), NOW()),
  ('es', 'onlineProvidersUseAnotherAccount', 'Usar otra cuenta de {provider}', NOW(), NOW()),
  ('he', 'onlineProvidersUseAnotherAccount', 'השתמש בחשבון {provider} אחר', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersChooseGoogleAccount', 'Choose a Google account', NOW(), NOW()),
  ('es', 'onlineProvidersChooseGoogleAccount', 'Elige una cuenta de Google', NOW(), NOW()),
  ('he', 'onlineProvidersChooseGoogleAccount', 'בחר חשבון Google', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersChooseOutlookAccount', 'Choose an Outlook account', NOW(), NOW()),
  ('es', 'onlineProvidersChooseOutlookAccount', 'Elige una cuenta de Outlook', NOW(), NOW()),
  ('he', 'onlineProvidersChooseOutlookAccount', 'בחר חשבון Outlook', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersAccountPickerHelp', 'Choose an available account or add another one.', NOW(), NOW()),
  ('es', 'onlineProvidersAccountPickerHelp', 'Elige una cuenta disponible o agrega otra.', NOW(), NOW()),
  ('he', 'onlineProvidersAccountPickerHelp', 'בחר חשבון זמין או הוסף חשבון נוסף.', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersAccountAdded', '{account} is ready to import.', NOW(), NOW()),
  ('es', 'onlineProvidersAccountAdded', '{account} está lista para importar.', NOW(), NOW()),
  ('he', 'onlineProvidersAccountAdded', '{account} מוכן לייבוא.', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersAppleUrlTitle', 'Paste Apple calendar URL', NOW(), NOW()),
  ('es', 'onlineProvidersAppleUrlTitle', 'Pega la URL del calendario de Apple', NOW(), NOW()),
  ('he', 'onlineProvidersAppleUrlTitle', 'הדבק את כתובת ה-URL של יומן Apple', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersImportSelected', 'Import Selected ({count})', NOW(), NOW()),
  ('es', 'onlineProvidersImportSelected', 'Importar seleccionados ({count})', NOW(), NOW()),
  ('he', 'onlineProvidersImportSelected', 'ייבא נבחרים ({count})', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersSummaryTitle', 'Online calendars', NOW(), NOW()),
  ('es', 'onlineProvidersSummaryTitle', 'Calendarios en línea', NOW(), NOW()),
  ('he', 'onlineProvidersSummaryTitle', 'יומנים מקוונים', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersSummaryBody', '{accounts} accounts connected · {events} events found · {selected} selected', NOW(), NOW()),
  ('es', 'onlineProvidersSummaryBody', '{accounts} cuentas conectadas · {events} eventos encontrados · {selected} seleccionados', NOW(), NOW()),
  ('he', 'onlineProvidersSummaryBody', '{accounts} חשבונות מחוברים · {events} אירועים נמצאו · {selected} נבחרו', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersAllAccounts', 'All accounts', NOW(), NOW()),
  ('es', 'onlineProvidersAllAccounts', 'Todas las cuentas', NOW(), NOW()),
  ('he', 'onlineProvidersAllAccounts', 'כל החשבונות', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersSelectionSummary', '{selected} of {available} selected', NOW(), NOW()),
  ('es', 'onlineProvidersSelectionSummary', '{selected} de {available} seleccionados', NOW(), NOW()),
  ('he', 'onlineProvidersSelectionSummary', '{selected} מתוך {available} נבחרו', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersNoEventsForFilter', 'No events are available for this account.', NOW(), NOW()),
  ('es', 'onlineProvidersNoEventsForFilter', 'No hay eventos disponibles para esta cuenta.', NOW(), NOW()),
  ('he', 'onlineProvidersNoEventsForFilter', 'אין אירועים זמינים עבור החשבון הזה.', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'onlineProvidersAccountStats', '{events} events · {calendars} calendars', NOW(), NOW()),
  ('es', 'onlineProvidersAccountStats', '{events} eventos · {calendars} calendarios', NOW(), NOW()),
  ('he', 'onlineProvidersAccountStats', '{events} אירועים · {calendars} יומנים', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'eventNoTitle', 'Untitled event', NOW(), NOW()),
  ('es', 'eventNoTitle', 'Evento sin título', NOW(), NOW()),
  ('he', 'eventNoTitle', 'אירוע ללא כותרת', NOW(), NOW())
ON CONFLICT (locale, key) DO NOTHING;

-- Verify the insertions
SELECT locale, key, value 
FROM translations 
WHERE key IN (
  'onlineProvidersAddAccount',
  'onlineProvidersRemoveAccount',
  'onlineProvidersRemoveAccountConfirm',
  'onlineProvidersNoAccounts', 
  'onlineProvidersAddAccountHint',
  'onlineProvidersNoEvents',
  'onlineProvidersEvents',
  'calendarSyncConnectedAccounts',
  'calendarSyncNoAccounts', 
  'calendarSyncAddAccountHint',
  'calendarSyncNoEvents',
  'calendarSyncNoEventsHint',
  'calendarSyncSelectProvider',
  'calendarSyncAddAccount',
  'onlineProvidersAccountRefreshFailed',
  'onlineProvidersReconnectRequired',
  'onlineProvidersAvailableAccount',
  'onlineProvidersUseAnotherAccount',
  'onlineProvidersChooseGoogleAccount',
  'onlineProvidersChooseOutlookAccount',
  'onlineProvidersAccountPickerHelp',
  'onlineProvidersAccountAdded',
  'onlineProvidersAppleUrlTitle',
  'onlineProvidersImportSelected',
  'onlineProvidersSummaryTitle',
  'onlineProvidersSummaryBody',
  'onlineProvidersAllAccounts',
  'onlineProvidersSelectionSummary',
  'onlineProvidersNoEventsForFilter',
  'onlineProvidersAccountStats',
  'eventNoTitle'
)
ORDER BY key, locale;
