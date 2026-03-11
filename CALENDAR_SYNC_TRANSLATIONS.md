# Calendar Sync Translation Keys

Add these keys to your Supabase `translations` table:

## UI Text
- `calendarSyncTitle` - "Sync Calendar"
- `calendarSyncConnectMessage` - "Connect your calendar to sync events"
- `calendarSyncConnectGoogle` - "Connect Google Calendar"
- `calendarSyncConnectOutlook` - "Connect Outlook Calendar"
- `calendarSyncLoadOutlookCalendars` - "Load Outlook Calendars"
- `calendarSyncLoadCalendars` - "Load Calendars"
- `calendarSyncNext` - "Next"
- `calendarSyncSyncSelected` - "Sync Selected"
- `calendarSyncChangeCalendars` - "Change Calendars"

## Empty State Messages
- `calendarSyncNoCalendarsFound` - "No calendars found"
- `calendarSyncNoCalendarsOutlook` - "Unable to retrieve Outlook calendars.\n\nPlease ensure you have granted calendar permissions and try again."
- `calendarSyncNoCalendarsGoogle` - "If the Google Sign-In popup did not appear, you may need to configure your Google Client ID.\n\nAdd <meta name=\"google-signin-client_id\" content=\"YOUR_CLIENT_ID\"> to web/index.html"

## Action Buttons
- `calendarSyncRetry` - "Retry"
- `calendarSyncSwitchToGoogle` - "Switch to Google"
- `calendarSyncSwitchToOutlook` - "Switch to Outlook"

## Error Messages
- `calendarSyncOutlookNotConfigured` - "Outlook is not configured. Please contact support or configure OUTLOOK_TENANT_ID, OUTLOOK_CLIENT_ID, and OUTLOOK_REDIRECT_URI in settings."
- `calendarSyncOutlookSignIn` - "Please sign in to Outlook to continue."
- `calendarSyncPermissionDenied` - "Calendar access is required. Please grant permission in your device settings."
- `calendarSyncPermissionFailed` - "Failed to request calendar permissions. Please try again."
- `calendarSyncOutlookWebOnly` - "Outlook calendar sync is currently only available on the web version."
- `calendarSyncOutlookExpired` - "Your Outlook session has expired. Please sign in again."
- `calendarSyncOutlookFailed` - "Failed to fetch Outlook calendars. Please try again later."
- `calendarSyncNetworkError` - "Network error. Please check your internet connection."
- `calendarSyncTimeout` - "Request timed out. Please try again."
- `calendarSyncUnexpectedError` - "An unexpected error occurred. Please try again."
- `calendarSyncOutlookEventsFailed` - "Failed to fetch Outlook events. Please try again later."

## SQL Insert Example

```sql
INSERT INTO translations (key, value, locale) VALUES
-- UI Text (English)
('calendarSyncTitle', 'Sync Calendar', 'en'),
('calendarSyncConnectMessage', 'Connect your calendar to sync events', 'en'),
('calendarSyncConnectGoogle', 'Connect Google Calendar', 'en'),
('calendarSyncConnectOutlook', 'Connect Outlook Calendar', 'en'),
('calendarSyncLoadOutlookCalendars', 'Load Outlook Calendars', 'en'),
('calendarSyncLoadCalendars', 'Load Calendars', 'en'),
('calendarSyncNext', 'Next', 'en'),
('calendarSyncSyncSelected', 'Sync Selected', 'en'),
('calendarSyncChangeCalendars', 'Change Calendars', 'en'),

-- Empty State Messages (English)
('calendarSyncNoCalendarsFound', 'No calendars found', 'en'),
('calendarSyncNoCalendarsOutlook', 'Unable to retrieve Outlook calendars.\n\nPlease ensure you have granted calendar permissions and try again.', 'en'),
('calendarSyncNoCalendarsGoogle', 'If the Google Sign-In popup did not appear, you may need to configure your Google Client ID.\n\nAdd <meta name="google-signin-client_id" content="YOUR_CLIENT_ID"> to web/index.html', 'en'),

-- Action Buttons (English)
('calendarSyncRetry', 'Retry', 'en'),
('calendarSyncSwitchToGoogle', 'Switch to Google', 'en'),
('calendarSyncSwitchToOutlook', 'Switch to Outlook', 'en'),

-- Error Messages (English)
('calendarSyncOutlookNotConfigured', 'Outlook is not configured. Please contact support or configure OUTLOOK_TENANT_ID, OUTLOOK_CLIENT_ID, and OUTLOOK_REDIRECT_URI in settings.', 'en'),
('calendarSyncOutlookSignIn', 'Please sign in to Outlook to continue.', 'en'),
('calendarSyncPermissionDenied', 'Calendar access is required. Please grant permission in your device settings.', 'en'),
('calendarSyncPermissionFailed', 'Failed to request calendar permissions. Please try again.', 'en'),
('calendarSyncOutlookWebOnly', 'Outlook calendar sync is currently only available on the web version.', 'en'),
('calendarSyncOutlookExpired', 'Your Outlook session has expired. Please sign in again.', 'en'),
('calendarSyncOutlookFailed', 'Failed to fetch Outlook calendars. Please try again later.', 'en'),
('calendarSyncNetworkError', 'Network error. Please check your internet connection.', 'en'),
('calendarSyncTimeout', 'Request timed out. Please try again.', 'en'),
('calendarSyncUnexpectedError', 'An unexpected error occurred. Please try again.', 'en'),
('calendarSyncOutlookEventsFailed', 'Failed to fetch Outlook events. Please try again later.', 'en');
```

## Adding Translations for Other Languages

For each language your app supports, add rows with the same keys but translated values. For example, for Hebrew (he):

```sql
INSERT INTO translations (key, value, locale) VALUES
('calendarSyncTitle', 'סנכרון יומן', 'he'),
('calendarSyncConnectMessage', 'חבר את היומן שלך לסנכרון אירועים', 'he'),
('calendarSyncConnectGoogle', 'התחבר ליומן Google', 'he'),
('calendarSyncConnectOutlook', 'התחבר ליומן Outlook', 'he'),
-- ... and so on for all keys
```
