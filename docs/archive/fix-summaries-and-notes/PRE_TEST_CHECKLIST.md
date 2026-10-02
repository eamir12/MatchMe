# Pre-Test Checklist

## Before You Start

- [ ] You have the latest code with the logging changes
- [ ] You have Flutter installed and working
- [ ] You have an Android device or emulator connected
- [ ] You have internet connection on the device
- [ ] You're logged into the app

## Build Phase

- [ ] Run `flutter clean`
- [ ] Run `flutter build apk --release`
- [ ] Build completes without errors
- [ ] Run `flutter install --release`
- [ ] Installation completes successfully

## Logging Phase

- [ ] Open a NEW terminal window
- [ ] Run `flutter logs` in the new terminal
- [ ] Keep this terminal open during the test
- [ ] You see logs appearing (bootstrap logs)

## Test Phase

- [ ] Close the app completely (swipe from recent apps)
- [ ] Open the app from home screen
- [ ] Wait for app to fully load
- [ ] Tap the "Online" button/tab
- [ ] Wait 2-3 seconds
- [ ] Watch Terminal 2 for logs

## Expected Results

### ✅ If You See Success Logs
- [ ] You see `🗺️ OnlineWorldMapScreen: initState called`
- [ ] You see `✅ OnlineWorldMapScreen: User activity updated - user marked as ONLINE`
- [ ] You see `🗺️ OnlineWorldMapScreen: _refresh() - complete`
- [ ] The map shows a number (not "Online: 0")

### ❌ If You See Error Logs
- [ ] You see `❌ OnlineWorldMapScreen: CRITICAL - Failed to update user activity:`
- [ ] You see the error message after the colon
- [ ] The map shows "Online: 0"

## Data Collection

- [ ] Copy the complete log output
- [ ] Take a screenshot of the Online map showing the count
- [ ] Note any error messages
- [ ] Note the timestamp

## Ready to Share

- [ ] You have the log output
- [ ] You have a screenshot
- [ ] You have any error messages
- [ ] You're ready to share with me

## Troubleshooting Checklist

If something goes wrong:

- [ ] Check if the app is actually running: `flutter devices`
- [ ] Check if you're on the Online map screen
- [ ] Try: `flutter logs --clear` then open the map again
- [ ] Try: `flutter logs | grep "OnlineWorldMapScreen"` to filter logs
- [ ] Check if the device has internet connection
- [ ] Check if location services are enabled on the device
- [ ] Check if location permission is granted to the app

## Final Verification

Before sharing results:

- [ ] I have the complete log output
- [ ] I have a screenshot of the Online map
- [ ] I have any error messages
- [ ] I know whether it shows "Online: 0" or a number
- [ ] I'm ready to share

---

## Quick Command Reference

```bash
# Terminal 1: Build
flutter clean
flutter build apk --release
flutter install --release

# Terminal 2: Logs
flutter logs

# Filter logs (if needed)
flutter logs | grep "OnlineWorldMapScreen"

# Save logs to file
flutter logs > online_map_logs.txt
```

## What to Share

1. **Log output** - Copy from Terminal 2
2. **Screenshot** - Show the Online map with the count
3. **Error messages** - Any ❌ or ⚠️ messages
4. **Device info** - Device model and Android version

---

**Status**: Ready to test ✅

**Next Step**: Follow the EXACT_TEST_COMMANDS.md guide
