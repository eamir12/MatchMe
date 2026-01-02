# Location Accuracy Analysis: Web vs Mobile

## Problem
Two test users (one on Edge browser, one on Android) are reporting locations far from each other even though the devices are physically next to each other.

## Key Differences Between Web and Mobile Location Services

### Web Location Service (Edge Browser)
**File**: `lib/services/web_location_service.dart`

1. **Location Source**: 
   - Web browsers use WiFi-based geolocation (IP geolocation, WiFi network databases)
   - NOT true GPS hardware
   - Accuracy typically: **50-500+ meters** (or worse, especially indoors)
   - Can be very inaccurate if WiFi network location data is outdated or incorrect

2. **Accuracy Setting**: 
   - Uses `LocationAccuracy.best` (line 137)
   - However, "best" for web browsers is limited by WiFi-based location services

3. **Processing**:
   - Uses **Kalman filter** to smooth GPS data (line 309)
   - The Kalman filter might add drift if incorrectly modeling a stationary user
   - Filtered position is sent to Supabase

4. **Method**: 
   - Calls `getCurrentPosition()` with `LocationAccuracy.best`
   - Processes through Kalman filter before sending

### Mobile Location Service (Android)
**File**: `lib/services/mobile_location_service.dart`

1. **Location Source**:
   - Uses actual **GPS hardware** on the device
   - Accuracy typically: **5-10 meters** outdoors
   - Much more accurate than web browsers

2. **Accuracy Setting**:
   - Uses `LocationAccuracy.high` (line 151)

3. **Processing**:
   - **NO Kalman filter** - sends raw GPS data directly
   - Position sent to Supabase without filtering

4. **Method**:
   - Calls `Geolocator.getCurrentPosition()` with `LocationAccuracy.high`
   - Sends raw position directly

## Root Cause

The primary issue is the **fundamental difference in location sources**:

- **Web browsers (Edge)**: WiFi-based geolocation → often inaccurate (50-500+ meters error)
- **Mobile devices (Android)**: True GPS hardware → highly accurate (5-10 meters error)

Even with both devices in the same location, web browsers may report a location that's hundreds of meters away because:
1. WiFi network location databases can be outdated
2. The browser may be using IP-based geolocation if WiFi data is unavailable
3. Indoor locations are particularly inaccurate for WiFi-based services

## Additional Factors

1. **Kalman Filter on Web**: The Kalman filter on the web service could potentially add drift if it's incorrectly predicting movement for a stationary user. However, this is likely a secondary issue compared to the fundamental WiFi vs GPS accuracy difference.

2. **Accuracy Settings**: Both use high accuracy settings, but the underlying location source is the limiting factor.

## Recommendations for Debugging

1. **Check the actual accuracy values** reported by each device:
   - Look at the `accuracy` field in the `Position` objects
   - Web browser accuracy will likely show 50-200+ meters
   - Mobile GPS accuracy will likely show 5-20 meters

2. **Test outdoors**: 
   - Move both devices outdoors with clear sky view
   - GPS is more accurate outdoors
   - Web browser accuracy may still be poor

3. **Check Supabase logs**:
   - Look at the actual coordinates being stored
   - Compare with known ground truth location

4. **Consider logging the raw position accuracy**:
   - Add debug logs to show the `position.accuracy` value for both platforms
   - This will confirm if web browser accuracy is the issue

## Potential Solutions

1. **For Web Users**: 
   - Consider showing a warning if accuracy is > 50 meters
   - Suggest users move to a location with better WiFi/cellular signal
   - Consider using HTML5 Geolocation API with `enableHighAccuracy: true` (if not already)

2. **For Development/Testing**:
   - Use mobile devices for location testing when possible
   - Accept that web browser locations will be less accurate
   - Consider implementing location accuracy thresholds in your matching logic

3. **Code Changes to Consider**:
   - Add accuracy checks before sending location updates
   - Log accuracy values to help diagnose issues
   - Consider disabling Kalman filter for very inaccurate measurements (e.g., > 100m)

