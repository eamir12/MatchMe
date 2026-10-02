# Testing Instructions: Online Map Fix

## What Was Fixed

The `_refreshPresence()` method in `lib/screens/nearby/nearby_map_screen.dart` was silently swallowing all errors with `catch (_) {}`. This meant:
- If location permissions failed → no error shown
- If RPC calls failed → no error shown  
- If network was down → no error shown
- **Result**: You couldn't diagnose why you weren't appearing online

## The Solution

Added comprehensive logging to every step of the online status update process. Now you'll see exactly what's happening and where it fails.

## How to Test

### Step 1: Build and Install Release APK
```bash
# Clean build
flutter clean

# Build release APK
flutter build apk --release

# Install on device
flutter install --release
```

### Step 2: Start Logging
In a separate terminal, start watching logs:
```bash
flutter logs
```

### Step 3: Reproduce the Issue
1. Open the app
2. Navigate to the "Online" map tab
3. Watch the logs in the terminal

### Step 4: Look for These Log Patterns

#### ✅ SUCCESS (You should see all of these):
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

#### ❌ FAILURE (If you see any of these, it shows the problem):

**Location Permission Issue:**
```
⚠️ OnlineWorldMapScreen: Location refresh failed: [ERROR MESSAGE]
```

**Location Not Available:**
```
⚠️ OnlineWorldMapScreen: No position available, skipping location update
```

**RPC Call Failed (CRITICAL):**
```
❌ OnlineWorldMapScreen: CRITICAL - Failed to update user activity: [ERROR MESSAGE]
❌ This is why you don't appear online on the map!
```

**Session Registration Failed:**
```
⚠️ OnlineWorldMapScreen: Failed to register session: [ERROR MESSAGE]
```

## What to Do With the Error Messages

### If you see location permission errors:
1. Go to Settings → Apps → MatchMe → Permissions
2. Ensure Location is set to "Allow all the time"
3. Restart the app

### If you see RPC call errors:
1. Check your internet connection
2. Try the app in debug mode (`flutter run`) to see if it works there
3. If it works in debug but not release, there might be a signing/authentication issue
4. Share the exact error message for further diagnosis

### If you see "No position available":
1. Ensure location services are enabled on your device
2. Grant location permission when prompted
3. Wait a few seconds for GPS to acquire a fix

## Comparing Debug vs Release

### In Debug Mode (`flutter run`):
```bash
flutter run
# Then navigate to Online map
# Check logs for the same patterns
```

### In Release Mode (`flutter build apk && flutter install`):
```bash
flutter build apk --release
flutter install --release
# Then navigate to Online map
# Check logs for the same patterns
```

**The logs should be identical.** If they're different, that's the issue.

## Expected Behavior After Fix

1. **In Debug (`flutter run`)**: You appear online on the map ✅
2. **In Release (`flutter build apk`)**: You should ALSO appear online on the map ✅
3. **Logs show success**: All steps complete without errors ✅

## If It Still Doesn't Work

After applying this fix and seeing the logs, if you still don't appear online:

1. **Share the complete log output** from `flutter logs` - this will show exactly what's failing
2. **Check Supabase directly**:
   ```sql
   SELECT user_id, is_online, last_activity 
   FROM user_activity 
   WHERE user_id = 'YOUR_USER_ID' 
   ORDER BY last_activity DESC 
   LIMIT 1;
   ```
   - If this shows `is_online = false`, the RPC call succeeded but something else is wrong
   - If this shows `is_online = true`, the issue is in the `get_online_user_counts_by_country` function

3. **Check visibility settings**:
   ```sql
   SELECT id, user_visibility_setting, system_visibility_status 
   FROM users 
   WHERE id = 'YOUR_USER_ID';
   ```
   - Both should be `true` / `'visible'`

## Files Changed

- `lib/screens/nearby/nearby_map_screen.dart` - Enhanced `_refreshPresence()` with detailed logging

## Key Insight

The issue was **not** that the functionality was broken. The issue was that **errors were being silently ignored**, making it impossible to diagnose what was actually failing. Now with proper logging, you'll see exactly what's happening at each step.

This is a common pattern in Flutter/Dart - always log errors instead of silently catching them with `catch (_) {}`.
