-- Guide for triggering real location updates in the MatchMe app

/*
HOW TO TRIGGER REAL LOCATION UPDATES:

1. **Both users must do this simultaneously:**

   a) Open the MatchMe app on their devices
   b) Ensure location permissions are granted (Settings > Privacy > Location Services)
   c) Make sure GPS/location services are enabled on the device
   d) Navigate to a screen that uses location (like the main matching screen)

2. **Trigger location updates:**
   - Move the devices slightly (even 5-10 meters)
   - Switch between foreground/background on the app
   - Force close and reopen the app
   - Wait for the automatic location update cycle (every 1-5 minutes)

3. **Verify updates worked:**
   - Run the location freshness diagnostic query
   - Look for 'VERY_FRESH (<2min)' status
   - Run the distance calculation again

4. **If updates still don't work:**
   - Check device GPS accuracy (high accuracy mode)
   - Restart both devices
   - Check network connectivity
   - Verify the app has location permissions

5. **Test matching:**
   - Once locations are fresh, run the distance/intents/interests query
   - Should show distance < 50 meters and WITHIN_RANGE
   - Matching should happen automatically or can be triggered manually

WHY THIS HAPPENS:
- Location updates don't happen instantly
- Apps batch location updates to save battery
- GPS accuracy can vary
- Network conditions affect update frequency
*/
