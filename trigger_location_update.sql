-- Trigger location updates in the app
-- Instructions for users to update their locations

/*
TO TRIGGER LOCATION UPDATES IN THE APP:

1. **Both users should:**
   - Open the MatchMe app
   - Go to the main screen where location services are active
   - The app should automatically update locations every few minutes
   - Or manually trigger by:
     - Switching between foreground/background
     - Refreshing the main screen
     - Opening location settings

2. **If locations aren't updating:**
   - Check that location permissions are granted
   - Ensure GPS/location services are enabled on device
   - Try restarting the app
   - Check if location services are working (test with Google Maps)

3. **Alternative: Manual location update**
   - Have both users move slightly (even 10-20 meters)
   - Or wait for the next automatic location update cycle

4. **Monitor location updates:**
   - Run this query to see when locations get updated
*/

SELECT
    'LOCATION_UPDATE_MONITOR' as info,
    ul.user_id,
    u.name,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_since_update,
    CASE
        WHEN ul.updated_at >= NOW() - INTERVAL '5 minutes' THEN 'JUST_UPDATED'
        WHEN ul.updated_at >= NOW() - INTERVAL '15 minutes' THEN 'RECENTLY_UPDATED'
        WHEN ul.updated_at >= NOW() - INTERVAL '1 hour' THEN 'WITHIN_MATCHING_WINDOW'
        ELSE 'OLD_NEEDS_UPDATE'
    END as update_status
FROM user_locations ul
JOIN users u ON ul.user_id = u.id
WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
ORDER BY ul.updated_at DESC;
