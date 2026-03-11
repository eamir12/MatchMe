# Notification Settings - Quick Start Guide

## What Was Added

A complete notification settings feature for the MatchMe app that allows users to control:
- **Chat message notifications**
- **Match expiry alerts**
- **Admin announcements**
- **Notification sounds**
- **Vibration (mobile only)**
- **In-app notifications**

## Files Changed

### Modified Files:
1. `lib/providers/user_preferences_provider.dart` - Added notification preferences state and methods
2. `lib/screens/settings/settings_screen.dart` - Added notification settings navigation

### New Files:
1. `lib/screens/settings/notifications_settings_screen.dart` - Complete notification settings UI
2. `supabase/migrations/20260209000000_add_notification_settings_translations.sql` - Translations (EN, ES, HE)
3. `supabase/migrations/20260209000001_add_notification_preferences_to_users.sql` - Database column
4. `NOTIFICATION_SETTINGS_IMPLEMENTATION.md` - Complete documentation

## How to Deploy

### Step 1: Run Database Migrations
```bash
# Navigate to Supabase directory
cd supabase

# Run migrations
supabase migration up

# Or push to Supabase if using remote
supabase push
```

### Step 2: Verify Translations
```sql
-- Check if translations were added
SELECT COUNT(*) FROM translations 
WHERE key LIKE 'settingsNotifications%' AND locale IN ('en', 'es', 'he');
-- Should return 57 rows (19 keys × 3 languages)
```

### Step 3: Test the App
1. Open the app
2. Navigate to Settings
3. Scroll down to "Notifications" section
4. Tap to open Notifications Settings screen
5. Toggle settings and verify they:
   - Update locally
   - Persist after reload
   - Appear correctly in all 3 languages

## Accessing Notification Settings

**From Main Settings Screen:**
1. Tap Settings (⚙️) icon
2. Scroll down past "Gender & Age Preferences" and "Invisibility Rules"
3. Tap "Notifications" card
4. Configure your preferences

## How It Works

1. **Local Storage:** Settings are stored in SharedPreferences for instant load
2. **Cloud Sync:** Settings also store in Supabase `users.notification_preferences` JSONB column
3. **Real-time:** Changes sync to cloud immediately
4. **Offline Friendly:** Works offline, syncs when back online
5. **RTL Support:** Full support for Hebrew and other RTL languages

## Default Settings

When a user first accesses settings, all notifications are enabled:
- ✅ Chat messages notifications enabled
- ✅ Match expiry alerts enabled
- ✅ Admin announcements enabled
- ✅ Sound enabled
- ✅ Vibration enabled (mobile)
- ✅ In-app notifications enabled

## Integration with Services

To integrate with actual notification delivery:

```dart
// In your notification service
final prefs = ref.watch(userPreferencesProvider);
final notifPrefs = prefs.notifications;

// Check before showing chat notification
if (!notifPrefs.enableChatNotifications) {
  return; // Don't show
}

// Check sound setting
if (!notifPrefs.enableSound) {
  // Skip sound, only show visual
}

// Check vibration setting (mobile only)
if (!notifPrefs.enableVibration) {
  // Skip vibration
}
```

## Translation Keys Reference

All keys are prefixed with `settingsNotifications`:

```
settingsNotifications                    - Main title
settingsNotificationsTitle              - Settings screen title
settingsNotificationsDesc               - Settings screen description
settingsNotificationTypes               - Section header
settingsNotificationsChatMessages       - Chat notifications
settingsNotificationsChatMessagesDesc   - Chat description
settingsNotificationsMatchExpiry        - Match expiry alerts
settingsNotificationsMatchExpiryDesc    - Match expiry description
settingsNotificationsAdmin              - Admin announcements
settingsNotificationsAdminDesc          - Admin description
settingsNotificationPreferences         - Preferences section header
settingsNotificationsSound              - Sound toggle
settingsNotificationsSoundDesc          - Sound description
settingsNotificationsVibration          - Vibration toggle
settingsNotificationsVibrationDesc      - Vibration description
settingsNotificationsInApp              - In-app notifications
settingsNotificationsInAppDesc          - In-app description
settingsNotificationsInfo               - Info/help text
settingsNotificationsSettingsDesc       - Navigation description
```

## Troubleshooting

### Settings not saving?
- Check if user is logged in
- Check Supabase connection
- Check SharedPreferences writing
- Check browser console for errors

### Translations not showing?
- Run the translation migration
- Verify locale codes: 'en', 'es', 'he'
- Restart app to clear localization cache

### Vibration not showing?
- Should only show on mobile (iOS/Android)
- Check `if (!kIsWeb)` wrapper works correctly

## Notes

- All strings are database-backed for easy updating
- No hardcoded strings in the UI
- Full RTL support for Hebrew text
- Material Design 3 compliant
- Zero breaking changes to existing code
- Services can opt-in to use these settings
