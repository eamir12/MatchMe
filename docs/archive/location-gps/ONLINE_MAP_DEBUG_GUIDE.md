# Online Map Not Showing Users in Release Build - Troubleshooting Guide

## Problem
The online map works in `flutter run` (debug) but shows "Online: 0" in `flutter build apk && flutter install` (release).

## Root Causes Identified

### 1. **Silent Error Swallowing** ✅ FIXED
The `_refreshPresence()` method was using `catch (_) {}` which silently ignored all errors. This meant:
- Location permission failures were hidden
- RPC call failures were hidden
- No way to diagnose the actual problem

**Fix Applied:** Added comprehensive logging to see exactly what's failing.

### 2. **Possible Issues to Check**

#### A. Location Permissions Not Granted
In release builds, location permissions might not be granted. Check:
```
Settings → Apps → MatchMe → Permissions → Location
```
Should show: "Allow all the time" or "Allow only while using the app"

#### B. RPC Call Failures
The `update_user_activity` RPC might be failing due to:
- Authentication issues (token expired or invalid)
- Network connectivity problems
- Backend/Supabase issues
- Row-level security (RLS) policy blocking the update

#### C. Location Service Not Initialized
The location service might not be starting properly in release builds due to:
- Missing permissions
- Location services disabled on device
- Background location permission not granted (Android 10+)

#### D. Build Configuration Issues
- Debug signing vs Release signing
- ProGuard/R8 obfuscation removing necessary code
- Missing native libraries

## How to Diagnose

### Step 1: Check Logs
After installing the release APK, run:
```bash
flutter logs
```

Look for these log patterns:
- `🗺️ OnlineWorldMapScreen: _refreshPresence` - Shows when refresh starts
- `✅ OnlineWorldMapScreen: User activity updated - user marked as ONLINE` - Success
- `❌ OnlineWorldMapScreen: CRITICAL - Failed to update user activity:` - Failure (shows error)
- `⚠️ OnlineWorldMapScreen: Location refresh failed:` - Location permission issue

### Step 2: Check Device Settings
1. Open Settings → Apps → MatchMe → Permissions
2. Verify Location permission is granted
3. For Android 10+, check if "Allow all the time" is selected (needed for background location)

### Step 3: Check Network Connectivity
1. Ensure device has internet connection
2. Try opening the app in airplane mode, then disable it
3. Check if other network-dependent features work

### Step 4: Check Supabase Backend
1. Go to Supabase dashboard
2. Check `user_activity` table - should have recent entries for your user
3. Check `user_session` table - should have recent entries
4. Run this query to verify online status:
```sql
SELECT user_id, is_online, last_activity 
FROM user_activity 
WHERE user_id = 'YOUR_USER_ID' 
ORDER BY last_activity DESC 
LIMIT 1;
```

## Common Solutions

### Solution 1: Grant Location Permissions
1. Uninstall the app
2. Reinstall from release APK
3. When prompted, grant location permission
4. Select "Allow all the time" (not just "while using app")

### Solution 2: Clear App Data
1. Settings → Apps → MatchMe → Storage → Clear Data
2. Restart the app
3. Grant permissions again

### Solution 3: Check Build Configuration
Ensure release build is using correct signing:
```bash
flutter build apk --release
# or
flutter build apk --release --verbose
```

### Solution 4: Verify Backend Connectivity
Add this test to check if RPC calls work:
```dart
// In your app, temporarily add this test
try {
  final result = await Supabase.instance.client.rpc(
    'update_user_activity',
    params: {'p_user_id': userId},
  );
  print('✅ RPC call succeeded: $result');
} catch (e) {
  print('❌ RPC call failed: $e');
}
```

## What the Fix Does

The updated `_refreshPresence()` method now:
1. ✅ Logs when it starts and stops
2. ✅ Logs location refresh attempts and results
3. ✅ Logs location update attempts and results
4. ✅ **CRITICAL**: Logs `update_user_activity` failures with full error details
5. ✅ Logs session registration attempts and results
6. ✅ Clearly marks which step is failing

## Next Steps

1. **Install the updated app** with the new logging
2. **Run `flutter logs`** while using the app
3. **Navigate to the Online map** and watch the logs
4. **Share the error messages** from the logs - they will show exactly what's failing

## Expected Log Output (Success Case)

```
🗺️ OnlineWorldMapScreen: _refreshPresence start for user=abc123 platform=android
🗺️ OnlineWorldMapScreen: Refreshing location...
✅ OnlineWorldMapScreen: Location refreshed successfully
🗺️ OnlineWorldMapScreen: Current position: -12.345,67.890
🗺️ OnlineWorldMapScreen: Updating user location...
✅ OnlineWorldMapScreen: User location updated successfully
🗺️ OnlineWorldMapScreen: Updating user activity (marking as online)...
✅ OnlineWorldMapScreen: User activity updated - user marked as ONLINE
🗺️ OnlineWorldMapScreen: Registering session...
✅ OnlineWorldMapScreen: Session registered successfully
🗺️ OnlineWorldMapScreen: _refreshPresence complete
```

## Expected Log Output (Failure Case)

If you see:
```
❌ OnlineWorldMapScreen: CRITICAL - Failed to update user activity: [ERROR MESSAGE]
```

This is the exact error preventing you from appearing online. Share this error message for further diagnosis.

## Additional Checks

### Check if visibility provider is working
The `IsVisible` provider controls whether GPS tracking is enabled. If the user is marked as invisible, location updates won't happen.

Check in Supabase:
```sql
SELECT id, user_visibility_setting, system_visibility_status 
FROM users 
WHERE id = 'YOUR_USER_ID';
```

Both should be `true` / `'visible'`.

### Check if connectivity provider is working
The app won't update online status if it thinks it's offline. Check logs for:
```
🟢 Connectivity restored
```

If you see `🟠 Connectivity lost`, the app thinks it's offline.

## Still Not Working?

If the logs show everything succeeding but you still don't appear online:
1. Check the `get_online_user_counts_by_country` RPC function in Supabase
2. Verify the function is querying `user_activity` table correctly
3. Check if there's a time zone issue (last_activity timestamp)
4. Verify RLS policies aren't blocking reads

## Files Modified

- `lib/screens/nearby/nearby_map_screen.dart` - Added comprehensive logging to `_refreshPresence()`
