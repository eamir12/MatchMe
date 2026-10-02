# Enhanced Logging Test Guide

## What Changed

I've added **even more detailed logging** to track exactly when and where the Online map screen is being opened and what's happening.

## New Logging Points

### 1. Screen Initialization
```
🗺️ OnlineWorldMapScreen: initState called
🗺️ OnlineWorldMapScreen: Calling _refresh from initState
```

### 2. Refresh Method
```
🗺️ OnlineWorldMapScreen: _refresh() called
🗺️ OnlineWorldMapScreen: _refresh() - setting loading state
🗺️ OnlineWorldMapScreen: _refresh() - calling _refreshPresence()
🗺️ OnlineWorldMapScreen: _refresh() - _refreshPresence() completed
🗺️ OnlineWorldMapScreen: _refresh() - calling get_online_user_counts_by_country RPC
🗺️ OnlineWorldMapScreen: _refresh() - RPC completed
🗺️ OnlineWorldMapScreen: _refresh() - parsed X countries with online users
🗺️ OnlineWorldMapScreen: _refresh() - success, updated UI with X countries
🗺️ OnlineWorldMapScreen: _refresh() - complete
```

### 3. Presence Update (Your Online Status)
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

## How to Test

### Step 1: Clean Build
```bash
flutter clean
```

### Step 2: Build Release APK
```bash
flutter build apk --release
```

### Step 3: Install on Device
```bash
flutter install --release
```

### Step 4: Start Logs in Terminal
```bash
flutter logs
```

### Step 5: Open the App
- Launch the app on your device
- Wait for it to fully load

### Step 6: Navigate to Online Map
- Tap on the "Online" tab or button
- This should trigger the logs

### Step 7: Watch for Logs
You should see logs starting with:
```
🗺️ OnlineWorldMapScreen: initState called
```

## What to Look For

### ✅ SUCCESS SCENARIO
You should see all these logs in order:
1. `initState called`
2. `Calling _refresh from initState`
3. `_refresh() called`
4. `_refreshPresence start for user=...`
5. `Location refreshed successfully`
6. `User activity updated - user marked as ONLINE`
7. `RPC completed`
8. `parsed X countries with online users`
9. `_refresh() - complete`

### ❌ FAILURE SCENARIOS

**If you DON'T see any logs:**
- The screen might not be opening
- Logs might be filtered
- Try: `flutter logs | grep "OnlineWorldMapScreen"`

**If you see `initState called` but NOT `_refresh() called`:**
- The Future.microtask might not be executing
- There might be an exception in initState

**If you see `_refreshPresence start` but NOT `User activity updated`:**
- The RPC call is failing
- Look for the ❌ error message

**If you see `RPC completed` but NOT `parsed X countries`:**
- The `get_online_user_counts_by_country` RPC is failing
- Look for the ❌ error message

## Exact Steps to Reproduce

1. **Close the app completely** (swipe it away from recent apps)
2. **Run**: `flutter logs`
3. **Open the app**
4. **Wait for it to load**
5. **Tap the Online map button**
6. **Watch the logs** - you should see the logs appear within 2-3 seconds

## If You Still Don't See Logs

Try these commands:

```bash
# Clear logs
flutter logs --clear

# Start fresh logs
flutter logs

# In another terminal, open the app and navigate to Online map
```

Or try filtering:
```bash
flutter logs | grep "OnlineWorldMapScreen"
```

## Expected Timeline

- **0-2 seconds**: App loads, you see bootstrap logs
- **2-5 seconds**: You navigate to Online map
- **5-7 seconds**: You should see `initState called` log
- **7-10 seconds**: You should see all the `_refresh()` logs

## Files Modified

- `lib/screens/nearby/nearby_map_screen.dart`
  - Enhanced `initState()` with logging
  - Enhanced `_refresh()` with detailed logging
  - Enhanced `_refreshPresence()` with detailed logging (already done)

## Next Steps After Testing

1. **Share the complete log output** from when you open the Online map
2. **Include the timestamp** so I can see the exact sequence
3. **Include any error messages** (look for ❌ symbols)
4. **Include the final state** (does it show "Online: 0" or a number?)

## Troubleshooting the Logs

### Logs are too verbose
Filter by the screen name:
```bash
flutter logs | grep "OnlineWorldMapScreen"
```

### Logs are cut off
Increase the buffer:
```bash
flutter logs --clear
flutter logs
```

### Still not seeing logs
The screen might not be opening. Try:
1. Check if you're actually on the Online map screen
2. Look for any error messages in the logs
3. Try restarting the app

## What This Will Tell Us

Once you share the logs, I'll be able to see:
- ✅ If the screen is opening
- ✅ If the refresh is being called
- ✅ If location is working
- ✅ If the RPC calls are succeeding
- ✅ If the data is being fetched
- ✅ Exactly where it's failing (if at all)

This will give us the exact information needed to fix the issue.
