# Location Accuracy Comparison

## Actual Distance Between Locations

- **Google Maps location**: 41.2888252, -72.7827484
- **Our app location**: 41.2942336, -72.794112
- **Distance**: 1,123.85 meters (~1.12 km / ~3,687 feet)
- **Our app's reported accuracy**: 1,221.84 meters

## Key Finding

The actual distance (1,123m) is almost exactly equal to the reported accuracy (1,221m), which means:
- The browser correctly knows the location is inaccurate
- The accuracy circle does include the Google Maps location
- Our app is likely getting **IP-based geolocation** (very poor accuracy)
- Google Maps web is getting **WiFi/GPS-based location** (much better accuracy)

## Why the Difference?

Since both use the browser's Geolocation API:

**Google Maps Web likely:**
- Uses `watchPosition()` for continuous refinement
- Forces fresh data with `maximumAge: 0`
- Waits longer for better accuracy
- Uses optimal API parameters

**Our App:**
- Uses `getCurrentPosition()` (one-off calls)
- May be getting cached data
- May not be waiting long enough for GPS/WiFi
- The geolocator package might not expose all options

## The Solution

We should:
1. Use `getPositionStream()` instead of periodic `getCurrentPosition()` calls
2. Allow location to refine over time (watchPosition pattern)
3. Verify we're requesting fresh data (maximumAge: 0)
4. Wait longer for initial GPS/WiFi acquisition

