# Outlook Calendar Integration on Android

## Overview
This document explains how the MatchMe app handles Outlook calendar integration on Android devices and the technical limitations involved.

## Android Security Model & Limitations

### Why Direct Outlook App Communication Isn't Possible
Android's security model **sandboxes each app** to protect user data and privacy. This means:

1. **No Direct Inter-App Calendar Access**: Apps cannot directly communicate with other apps' private data
2. **Microsoft Outlook App Design**: The Outlook app for Android does NOT expose its calendar data to third-party apps via:
   - Content Providers
   - Intent-based APIs  
   - Any public interface

3. **Only Available Methods**:
   - **System Calendar Sync**: User manually enables Outlook→Android Calendar sync in Android Settings
   - **Microsoft Graph API**: Cloud-based OAuth authentication (requires internet, web-based)

### What This Means for Users
If a user has the Outlook app installed on their Android device:
- The app **cannot automatically detect or access Outlook calendars**
- Outlook calendars will **only appear** if the user has manually configured Android Calendar sync
- Even with the Outlook app installed, **no calendar data is available** unless synced to the system

## Implementation Approach

### 1. Native Android Code (MainActivity.kt)
```kotlin
// New MethodChannel: com.example.matchme/app_check
appCheckChannel?.setMethodCallHandler { call, result ->
    when (call.method) {
        "isAppInstalled" -> {
            // Check if package exists using PackageManager
            // Returns true/false for package: com.microsoft.office.outlook
        }
        "openAppSettings" -> {
            // Opens Android's app-specific settings screen
            // User can then find sync settings from there
        }
    }
}
```

### 2. Flutter Service (CalendarSyncService)
```dart
// Detect Outlook app installation
Future<bool> isOutlookInstalled() async {
  if (kIsWeb) return false;
  
  const methodChannel = MethodChannel('com.example.matchme/app_check');
  return await methodChannel.invokeMethod('isAppInstalled', {
    'packageName': 'com.microsoft.office.outlook',
  }) ?? false;
}

// Open Outlook settings to guide user
Future<void> openOutlookSettings() async {
  if (kIsWeb) return;
  
  const methodChannel = MethodChannel('com.example.matchme/app_check');
  await methodChannel.invokeMethod('openAppSettings', {
    'packageName': 'com.microsoft.office.outlook',
  });
}
```

### 3. Enhanced UI (CalendarSyncScreen)
When Outlook is selected and no calendars are found:

1. **Check if Outlook is installed** using `isOutlookInstalled()`
2. **Show different messages**:
   - If installed: "Outlook app detected! Enable calendar sync in Android settings to see your Outlook calendars."
   - If not installed: Standard instructions to add Microsoft account to Android

3. **Provide "Open Outlook Settings" button** (when installed)
   - Opens Android Settings → Apps → Outlook
   - User can navigate to Accounts/Sync settings from there

4. **Fallback suggestion**: Direct user to use web version for OAuth-based access

## User Flow

### Scenario 1: Outlook Installed, No Calendars Synced
```
1. User selects "Outlook" provider
2. App detects 0 Outlook calendars
3. App calls isOutlookInstalled() → returns true
4. UI shows:
   - Icon: Mail outline
   - Title: "No calendars found"
   - Message: "Outlook app detected! Enable calendar sync..."
   - Button: "Open Outlook Settings"
   - Button: "Retry"
5. User taps "Open Outlook Settings"
6. Android Settings → Apps → Microsoft Outlook opens
7. User enables calendar sync in Android account settings
8. User returns to app, taps "Retry"
9. Calendars now appear!
```

### Scenario 2: Outlook Not Installed
```
1. User selects "Outlook" provider
2. App detects 0 Outlook calendars
3. App calls isOutlookInstalled() → returns false
4. UI shows:
   - Standard instructions to add Microsoft Exchange account
   - Suggestion to use web version
5. User follows instructions or uses web version
```

## Technical Details

### Calendar Detection Logic
The app filters device calendars using multiple criteria:

```dart
final isOutlook = accountType.contains('outlook') ||
    accountType.contains('exchange') ||
    accountType.contains('office') ||
    accountType.contains('microsoft') ||
    accountType.contains('hotmail') ||
    accountType.contains('live') ||
    accountType.contains('com.microsoft') ||
    accountName.contains('outlook') ||
    // ... similar checks for accountName and calendar name
```

### Platform Differences
| Platform | Method | Requires |
|----------|--------|----------|
| **Web** | Microsoft Graph API OAuth | Internet, Microsoft account |
| **Android/iOS** | Device calendar system | Manual sync setup |

### Translation Keys
```dart
'calendarSyncNoOutlookOnDevice': 'No Outlook calendars found...'
'calendarSyncOutlookDetected': 'Outlook app detected! Enable calendar sync...'
'calendarSyncOpenOutlookSettings': 'Open Outlook Settings'
```

## Debugging

### Check Calendar Detection
```dart
// Added debug logging in _fetchCalendars()
debugPrint('=== All Device Calendars ===');
for (var cal in _allCalendars) {
  debugPrint('Calendar: ${cal.name}, AccountType: ${cal.accountType}, AccountName: ${cal.accountName}');
}
debugPrint('Provider Detection - Google: $_hasGoogleCalendars, Outlook: $_hasOutlookCalendars');
debugPrint('Found ${calendars.length} Outlook calendars');
```

### Common Issues

**Issue**: Outlook installed but no calendars detected
- **Cause**: User hasn't enabled calendar sync in Android account settings
- **Solution**: Guide user to Android Settings → Accounts → Microsoft → Enable Calendar sync

**Issue**: Calendar sync enabled but still not appearing
- **Cause**: Sync may take time, or permissions not granted
- **Solution**: Force sync in Android Settings, restart app

**Issue**: Wrong provider showing
- **Cause**: accountType detection not matching
- **Solution**: Check debug logs, adjust detection keywords if needed

## Conclusion

While we cannot directly communicate with the Outlook app due to Android's security architecture, we provide:
1. **Clear detection** of Outlook installation
2. **Helpful guidance** to enable sync
3. **Quick access** to settings
4. **Fallback options** (web version with OAuth)

This approach balances user experience with technical constraints while maintaining security and privacy.
