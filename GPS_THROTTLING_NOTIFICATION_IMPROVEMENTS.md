# GPS Throttling Notification Improvements

## Changes Made

### Issues Addressed
1. **Persistent Notifications**: Throttling notifications now persist while throttling is active, instead of auto-dismissing after 6 seconds
2. **Visibility Awareness**: Notifications are only shown when the user is visible (not invisible), since GPS isn't accessed when invisible

### Modified Files

#### 1. `lib/providers/system_notification_provider.dart`
- Added `isPersistent` flag to `SystemNotification` class
- Added `notificationType` field to track notification types ('battery_throttle', 'stationary_throttle', etc.)
- Updated notification clearing logic to support persistent notifications
- Added `clearType()` method to clear specific notification types

#### 2. `lib/providers/visibility_provider.dart`
- Updated battery throttling notification to be persistent and type-tagged
- Added visibility check before showing notifications (only show when `state == true`)
- Added automatic clearing of throttle notifications when user goes invisible
- Implemented stationary throttling notification support
- Both battery and stationary throttle notifications now properly persist until condition clears

#### 3. `lib/widgets/system_notification_overlay.dart`
- Added dynamic icon selection based on notification type:
  - Battery throttle: `Icons.battery_alert_outlined`
  - Stationary throttle: `Icons.my_location`
  - Default: `Icons.info_outline`
- Hide close button for persistent notifications

#### 4. Database Migrations
- **New**: `supabase/migrations/20260119120000_add_gps_throttle_stationary_translation.sql`
  - Added translations for stationary throttling message in English, Hebrew, and Spanish
  - Made idempotent with ON CONFLICT clause
- **Updated**: `supabase/migrations/20260106120000_add_gps_throttle_low_battery_translation.sql`
  - Made idempotent with ON CONFLICT clause

## Behavior

### Battery Throttling
- **Trigger**: Battery ≤ configured threshold (default 15%) AND not charging
- **Action**: GPS interval forced to 60 seconds
- **Notification**: 
  - Shown only when user is VISIBLE
  - Persists until battery is charging/charged or above threshold
  - Shows battery icon
  - Message: "Low battery — GPS updates reduced to once every 60 seconds to save battery. This will resume when your device is charging or battery is above 15%."

### Stationary Throttling
- **Trigger**: User stationary (5+ GPS positions within threshold) AND Smart GPS enabled
- **Action**: GPS interval throttled to 60 seconds
- **Notification**:
  - Shown only when user is VISIBLE
  - Persists until user starts moving
  - Shows location icon
  - Message: "Not moving — GPS updates reduced to once every 60 seconds to save battery. This will resume when you start moving."

### Invisible Mode
- When user toggles to invisible, ALL throttle notifications are immediately cleared
- No throttle notifications are shown while invisible (even if throttling conditions are met)
- This makes sense because GPS location isn't accessed when invisible anyway

## Testing Recommendations

1. **Battery Throttling**: 
   - Set battery threshold to 60% in app_config
   - Verify notification appears when battery drops below 60%
   - Verify notification persists until charging or battery rises
   - Verify notification does NOT appear when invisible

2. **Stationary Throttling**:
   - Enable Smart GPS
   - Stay in one location until 5 GPS positions are recorded
   - Verify notification appears when detected as stationary
   - Start moving and verify notification clears

3. **Visibility Integration**:
   - Enable throttling (battery or stationary)
   - Toggle to invisible
   - Verify notification immediately disappears
   - Toggle back to visible
   - Verify notification reappears if throttling is still active
