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
- `calendarSyncPermissionBlocked` - "Calendar permissions were permanently denied. Please enable them in your device settings to continue."
- `calendarSyncPermissionTitle` - "Calendar Permission Required"
- `calendarSyncGoogleAuthRequired` - "Google Sign-In Required"
- `calendarSyncGoogleAuthRequiredMessage` - "To access your Google calendars, you need to sign in with your Google account."
- `calendarSyncGoogleAuthTimeout` - "Google authentication timed out. Check your internet connection and try again."
- `calendarSyncGoogleSignInCancelled` - "Sign-in was cancelled. Please try again."
- `calendarSyncOutlookWebOnly` - "Outlook calendar sync is currently only available on the web version."
- `calendarSyncOutlookExpired` - "Your Outlook session has expired. Please sign in again."
- `calendarSyncOutlookAuthTimeout` - "Outlook authentication timed out. Check your internet connection and try again."
- `calendarSyncOutlookFailed` - "Failed to fetch Outlook calendars. Please try again later."
- `calendarSyncNetworkError` - "Network error. Please check your internet connection."
- `calendarSyncTimeout` - "Request timed out. Please try again."
- `calendarSyncUnexpectedError` - "An unexpected error occurred. Please try again."
- `calendarSyncOutlookEventsFailed` - "Failed to fetch Outlook events. Please try again later."

## Settings Guide Messages
- `calendarSyncPermissionBlockedSettingsGuideAndroid` - "Calendar permissions were permanently denied. To enable them:\n\n1. Go to Settings > Apps > MatchMe\n2. Tap 'Permissions'\n3. Enable 'Calendar' permission\n4. Return to the app and try again"
- `calendarSyncPermissionBlockedSettingsGuideIos` - "Calendar permissions were permanently denied. To enable them:\n\n1. Go to Settings > Privacy & Security > Calendars\n2. Enable MatchMe\n3. Return to the app and try again"
- `calendarSyncPermissionBlockedSettingsGuide` - "Calendar permissions were permanently denied. Please enable calendar permissions for MatchMe in your device settings and try again."

## Action Labels
- `permActionNotNow` - "Not Now"
- `permActionOpenSettings` - "Open Settings"
- `cancel` - "Cancel"
- `signIn` - "Sign In"

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
('calendarSyncPermissionBlocked', 'Calendar permissions were permanently denied. Please enable them in your device settings to continue.', 'en'),
('calendarSyncPermissionTitle', 'Calendar Permission Required', 'en'),
('calendarSyncGoogleAuthRequired', 'Google Sign-In Required', 'en'),
('calendarSyncGoogleAuthRequiredMessage', 'To access your Google calendars, you need to sign in with your Google account.', 'en'),
('calendarSyncOutlookWebOnly', 'Outlook calendar sync is currently only available on web version.', 'en'),
('calendarSyncOutlookExpired', 'Your Outlook session has expired. Please sign in again.', 'en'),
('calendarSyncOutlookFailed', 'Failed to fetch Outlook calendars. Please try again later.', 'en'),
('calendarSyncNetworkError', 'Network error. Please check your internet connection.', 'en'),
('calendarSyncTimeout', 'Request timed out. Please try again.', 'en'),
('calendarSyncUnexpectedError', 'An unexpected error occurred. Please try again.', 'en'),
('calendarSyncOutlookEventsFailed', 'Failed to fetch Outlook events. Please try again later.', 'en'),

-- Settings Guide Messages (English)
('calendarSyncPermissionBlockedSettingsGuideAndroid', 'Calendar permissions were permanently denied. To enable them:\n\n1. Go to Settings > Apps > MatchMe\n2. Tap ''Permissions''\n3. Enable ''Calendar'' permission\n4. Return to the app and try again', 'en'),
('calendarSyncPermissionBlockedSettingsGuideIos', 'Calendar permissions were permanently denied. To enable them:\n\n1. Go to Settings > Privacy & Security > Calendars\n2. Enable MatchMe\n3. Return to the app and try again', 'en'),
('calendarSyncPermissionBlockedSettingsGuide', 'Calendar permissions were permanently denied. Please enable calendar permissions for MatchMe in your device settings and try again.', 'en'),

-- Action Labels (English)
('permActionNotNow', 'Not Now', 'en'),
('permActionOpenSettings', 'Open Settings', 'en'),
('cancel', 'Cancel', 'en'),
('signIn', 'Sign In', 'en');
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
