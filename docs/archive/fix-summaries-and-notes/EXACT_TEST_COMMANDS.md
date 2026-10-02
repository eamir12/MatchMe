# Exact Test Commands - Copy & Paste

## Terminal 1: Build and Install

```bash
# Navigate to your project directory
cd /path/to/MatchMe4

# Clean build
flutter clean

# Build release APK
flutter build apk --release

# Install on device
flutter install --release
```

## Terminal 2: Watch Logs

Open a **NEW terminal window** and run:

```bash
flutter logs
```

**Keep this terminal open while you test.**

## On Your Device

1. **Close the app completely** (swipe it away from recent apps)
2. **Open the app** from the home screen
3. **Wait for it to fully load** (you'll see the home screen)
4. **Tap the "Online" button/tab** to open the Online map
5. **Watch Terminal 2** for logs

## Expected Logs (In Order)

You should see these logs appear in Terminal 2:

```
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: initState called
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: Calling _refresh from initState
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: _refresh() called
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: _refresh() - setting loading state
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: _refresh() - calling _refreshPresence()
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: _refreshPresence start for user=abc123 platform=android
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: Refreshing location...
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: Location refreshed successfully
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: Current position: -12.345,67.890
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: Updating user location...
I/flutter ( 9972): [TIMESTAMP] ✅ OnlineWorldMapScreen: User location updated successfully
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: Updating user activity (marking as online)...
I/flutter ( 9972): [TIMESTAMP] ✅ OnlineWorldMapScreen: User activity updated - user marked as ONLINE
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: Registering session...
I/flutter ( 9972): [TIMESTAMP] ✅ OnlineWorldMapScreen: Session registered successfully
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: _refreshPresence complete
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: _refresh() - _refreshPresence() completed
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: _refresh() - calling get_online_user_counts_by_country RPC
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: _refresh() - RPC completed
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: _refresh() - parsed 5 countries with online users
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: _refresh() - success, updated UI with 5 countries
I/flutter ( 9972): [TIMESTAMP] 🗺️ OnlineWorldMapScreen: _refresh() - complete
```

## If You See Errors

Look for lines with ❌ or ⚠️:

```
❌ OnlineWorldMapScreen: CRITICAL - Failed to update user activity: [ERROR MESSAGE]
```

**Copy the entire error message and share it.**

## Filter Logs (Optional)

If the logs are too noisy, filter them:

```bash
flutter logs | grep "OnlineWorldMapScreen"
```

This will show ONLY the Online map logs.

## Copy Logs to File

To save the logs for sharing:

```bash
flutter logs > online_map_logs.txt
```

Then open the Online map and let it run for 10 seconds, then press Ctrl+C to stop.

## Troubleshooting

### "No logs appearing"
1. Make sure you're on the Online map screen
2. Try: `flutter logs --clear` then open the map again
3. Check if the app is actually running: `flutter devices`

### "Logs are cut off"
1. Scroll up in the terminal
2. Or save to file: `flutter logs > logs.txt`

### "App crashes when opening Online map"
1. Check the logs for error messages
2. Share the crash logs with me

## What to Share

After running the test, share:

1. **The complete log output** from when you open the Online map
2. **A screenshot** of the Online map showing "Online: 0" or the count
3. **Any error messages** (look for ❌ or ⚠️)
4. **The timestamp** of when you opened the map

## Example: How to Share Logs

```bash
# Run this to capture logs
flutter logs > online_map_test.txt

# Open the app and Online map
# Wait 10 seconds
# Press Ctrl+C to stop

# Now share the online_map_test.txt file
```

## Quick Checklist

- [ ] Ran `flutter clean`
- [ ] Ran `flutter build apk --release`
- [ ] Ran `flutter install --release`
- [ ] Opened `flutter logs` in a new terminal
- [ ] Closed the app completely
- [ ] Opened the app
- [ ] Tapped the Online map button
- [ ] Watched for logs with 🗺️ emoji
- [ ] Copied the logs or took a screenshot
- [ ] Ready to share results

## Next: Share Your Results

Once you've run the test, share:
1. The log output (or screenshot)
2. Whether you see "Online: 0" or a number
3. Any error messages

This will tell me exactly what's happening and how to fix it.
