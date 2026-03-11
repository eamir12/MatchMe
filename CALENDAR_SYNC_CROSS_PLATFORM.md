# Calendar Sync Cross-Platform Compatibility

## Overview
The MatchMe calendar sync feature works across all platforms (Android, iOS, Web, Windows, macOS) with platform-appropriate methods.

## Platform-Specific Implementation

### Mobile Platforms (Android & iOS)

#### Method: Device Calendar System
- Uses `device_calendar` plugin (v4.3.3)
- Accesses calendars synced to the device's native calendar app
- **No OAuth required** - works with already-configured accounts

#### Android
**How it works:**
1. User adds calendar accounts in Android Settings (Google, Outlook/Exchange)
2. Android syncs calendars to the system calendar database
3. App reads from system calendar via `device_calendar` plugin
4. Works with: Google Calendar, Outlook, Exchange, any CalDAV/CardDAV account

**Calendar Account Types Detected:**
- Google: `com.google`
- Outlook: `com.microsoft.office.outlook.USER_ACCOUNT`
- Exchange: `com.microsoft.exchange`

**Setup Instructions (shown in app):**
```
Settings → Accounts → Add Account → Microsoft Exchange/Outlook
Sign in and enable Calendar sync
```

**Outlook App Detection:**
- Native code checks if `com.microsoft.office.outlook` package is installed
- If installed, shows "Open Outlook Settings" button
- Guides user to enable calendar sync

#### iOS
**How it works:**
1. User adds accounts in iOS Settings → Calendar → Accounts
2. iOS syncs calendars to the system calendar
3. App accesses via `device_calendar` plugin
4. Requires calendar permissions

**Setup Instructions (shown in app):**
```
Settings → Calendar → Accounts → Add Account → Outlook.com
Sign in and enable Calendars
```

**Permissions Required:**
- `NSCalendarsUsageDescription` in Info.plist
- User must grant calendar access when prompted

### Desktop Platforms (Windows & macOS)

#### Method: Device Calendar System
- Uses `device_calendar` plugin
- Accesses system calendar applications

#### Windows
**How it works:**
1. Outlook Desktop or Windows Calendar app syncs calendars
2. Calendar data stored in Windows system calendar
3. App accesses via `device_calendar` plugin

**Supported:**
- Outlook Desktop (Microsoft 365, standalone)
- Windows Calendar app
- Any calendar synced to Windows

#### macOS
**How it works:**
1. Calendar.app syncs with iCloud, Google, Exchange, etc.
2. App accesses via `device_calendar` plugin

**Supported:**
- Apple Calendar.app
- Outlook for Mac
- Any account configured in Calendar.app

### Web Platform

#### Method: OAuth (Microsoft Graph API & Google Calendar API)
- Direct cloud-based authentication
- **Best method** for web users
- No device calendar sync required

#### Google Calendar (Web)
**How it works:**
1. User clicks "Connect Google Calendar"
2. OAuth flow via `google_sign_in` and Google Calendar API
3. Direct access to Google Calendar cloud
4. Token cached for subsequent requests

**Implementation:**
- Service: `WebCalendarService`
- Package: `google_sign_in: ^7.2.0`
- Scopes: `calendar.readonly`

#### Outlook Calendar (Web)
**How it works:**
1. User clicks "Connect Outlook Calendar"
2. OAuth flow via `aad_oauth` (Azure AD)
3. Microsoft Graph API access: `https://graph.microsoft.com/v1.0/me/calendars`
4. Token cached with 1-hour expiry

**Implementation:**
- Service: `CalendarSyncService.retrieveOutlookCalendars()`
- Package: `aad_oauth: ^1.0.1`
- API: Microsoft Graph v1.0
- Scopes: `User.Read`, `Calendars.Read`, `offline_access`

**Why OAuth on Web?**
- No access to local device calendar
- Direct cloud access is more reliable
- Works on any browser/device
- Better security (scoped permissions)

**Cannot Detect Outlook Desktop App on Web:**
- Browser security prevents detection of installed applications
- No MethodChannel communication in browser
- OAuth is the only available method

## Feature Comparison Matrix

| Feature | Android | iOS | Windows | macOS | Web |
|---------|---------|-----|---------|-------|-----|
| **Calendar Access Method** | Device Calendar | Device Calendar | Device Calendar | Device Calendar | OAuth API |
| **Google Calendar** | ✅ Via device sync | ✅ Via device sync | ✅ Via device sync | ✅ Via device sync | ✅ OAuth |
| **Outlook Calendar** | ✅ Via device sync | ✅ Via device sync | ✅ Via Outlook app | ✅ Via Calendar.app | ✅ OAuth |
| **Exchange Calendar** | ✅ Via device sync | ✅ Via device sync | ✅ Via Outlook | ✅ Via Calendar.app | ✅ OAuth |
| **Auto-detect Provider** | ✅ By account type | ✅ By account type | ✅ By account type | ✅ By account type | ❌ User selects |
| **Duplicate Detection** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Filter Holidays** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Auto-select Single Calendar** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Outlook App Detection** | ✅ Native check | ⚠️ Limited | ❌ Not needed | ❌ Not needed | ❌ Not possible |
| **Setup Instructions** | ✅ Platform-specific | ✅ Platform-specific | ✅ Platform-specific | ✅ Platform-specific | ✅ OAuth flow |

## Code Architecture

### Platform Detection
```dart
if (kIsWeb) {
  // Use OAuth API methods
  calendars = _selectedProvider == CalendarProvider.outlook
      ? await service.retrieveOutlookCalendars()  // Microsoft Graph
      : await service.retrieveCalendars();         // Google Calendar API
} else {
  // Use device calendar system (Android/iOS/Desktop)
  calendars = await service.retrieveCalendars();  // device_calendar plugin
  
  // Filter by provider based on account type
  if (_selectedProvider == CalendarProvider.outlook) {
    calendars = calendars.where((cal) => 
      cal.accountType?.contains('microsoft') || 
      cal.accountType?.contains('outlook') ||
      cal.accountType?.contains('exchange')
    ).toList();
  }
}
```

### Event Retrieval
```dart
// Web: Use appropriate OAuth API
if (kIsWeb && _selectedProvider == CalendarProvider.outlook) {
  events = await service.retrieveOutlookEvents(calendarId);  // Graph API
} else {
  // All other platforms: device calendar
  events = await service.retrieveEvents(calendarId);  // device_calendar
}
```

### Duplicate Detection (All Platforms)
```dart
// Normalize to UTC to handle timezone differences
String _createEventKey(String name, DateTime startTime) {
  final utcTime = startTime.toUtc();
  return '${name.toLowerCase().trim()}_${utcTime.year}_${utcTime.month}_${utcTime.day}_${utcTime.hour}_${utcTime.minute}';
}
```

## User Experience Flow

### Mobile (Android/iOS)
1. User opens Calendar Sync
2. App checks device for Google/Outlook calendars
3. Auto-detects which providers have calendars
4. Shows provider toggle (Google/Outlook)
5. Filters calendars by provider
6. If no calendars found:
   - Shows platform-specific setup instructions
   - Android: Offers "Open Outlook Settings" if app detected
7. If only 1 calendar: Auto-selects and shows events
8. If multiple: User selects, then clicks "Next"
9. Shows events, filters out duplicates automatically
10. User selects events, clicks "Sync Selected"

### Desktop (Windows/macOS)
- Same flow as mobile
- Calendar apps (Outlook, Calendar.app) should already be configured
- No special setup usually needed

### Web
1. User opens Calendar Sync
2. Selects provider (Google/Outlook)
3. Clicks "Connect [Provider] Calendar"
4. OAuth popup/redirect for authentication
5. Grants permissions
6. Returns to app with token
7. Shows calendars from cloud account
8. Rest of flow same as mobile

## Testing Checklist

### Android
- [ ] Google Calendar sync works
- [ ] Outlook app calendars detected and synced
- [ ] Exchange calendars work
- [ ] Holiday calendars filtered out
- [ ] Duplicates filtered correctly
- [ ] Timezone handling correct
- [ ] "Open Outlook Settings" button works

### iOS
- [ ] Google Calendar sync works
- [ ] Outlook.com calendars work
- [ ] iCloud calendars work (if supported)
- [ ] Calendar permissions requested
- [ ] Holiday calendars filtered out
- [ ] Duplicates filtered correctly

### Windows
- [ ] Outlook Desktop calendars accessible
- [ ] Windows Calendar app calendars work
- [ ] Holiday calendars filtered out
- [ ] Duplicates filtered correctly

### macOS
- [ ] Calendar.app calendars work
- [ ] Outlook for Mac calendars work
- [ ] Holiday calendars filtered out
- [ ] Duplicates filtered correctly

### Web
- [ ] Google OAuth flow works
- [ ] Outlook OAuth flow works
- [ ] Token caching works
- [ ] Token refresh works
- [ ] Holiday calendars filtered out
- [ ] Duplicates filtered correctly
- [ ] Works on Chrome, Firefox, Safari, Edge

## Known Limitations

### Mobile
1. **Outlook App Doesn't Auto-Sync on Android**: 
   - Microsoft Outlook app doesn't expose calendars to device calendar by default
   - User must manually enable sync in Android Settings → Accounts
   - App can detect if Outlook is installed and guide user

2. **iOS App Detection Limited**:
   - Cannot reliably detect if Outlook app is installed
   - No MethodChannel equivalent for iOS URL scheme checking

### Desktop
1. **Windows Calendar Permissions**: 
   - Some Windows configurations may restrict calendar access
   - User may need to enable calendar permissions in Windows Settings

2. **macOS Sandbox**:
   - Sandboxed apps need calendar entitlements
   - User must grant permission in macOS System Preferences

### Web
1. **Cannot Access Local Outlook Client**:
   - Browser cannot detect or access Outlook desktop application
   - OAuth is the only method (accesses Outlook.com cloud)
   - Events only from accounts synced to Outlook.com

2. **OAuth Configuration Required**:
   - Requires valid Azure AD app registration
   - Environment variables must be set:
     - `OUTLOOK_TENANT_ID`
     - `OUTLOOK_CLIENT_ID`
     - `OUTLOOK_REDIRECT_URI`

3. **Token Expiry**:
   - Access tokens expire after 1 hour
   - App handles refresh automatically
   - User may need to re-authenticate if offline for extended period

## Conclusion

The calendar sync feature is **fully cross-platform** with appropriate methods for each platform:
- **Mobile/Desktop**: Device calendar system (best for local calendars)
- **Web**: OAuth APIs (best for cloud access)

All platforms support:
- ✅ Google Calendar
- ✅ Outlook/Exchange calendars
- ✅ Duplicate detection (UTC-normalized)
- ✅ Holiday calendar filtering
- ✅ Auto-select single calendar
- ✅ Platform-specific setup instructions

The implementation automatically uses the best method for each platform without requiring user intervention.
