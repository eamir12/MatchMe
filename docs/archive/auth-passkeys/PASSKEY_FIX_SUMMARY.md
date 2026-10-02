# Passkey Error Fix Summary

## Problem
The passkey enrollment was failing with the error: "Could not add a passkey right now. Please try again."

## Root Cause
The app was making HTTP requests directly to Supabase Edge Functions, but Supabase Edge Functions require JWT authentication by default. The requests were being rejected with a 401 Unauthorized error because no valid JWT token was being sent.

## Solution

### 1. Updated Edge Functions
Modified all four passkey Edge Functions to handle requests more gracefully:
- `passkeys-registration-start` - No changes needed (already public)
- `passkeys-registration-finish` - Made authorization header optional
- `passkeys-authentication-start` - No changes needed (already public)
- `passkeys-authentication-finish` - Made authorization header optional

### 2. Updated App Code
Changed the passkey service to use Supabase's built-in `functions.invoke()` method instead of making raw HTTP requests:

**File**: `lib/services/passkey_auth_service.dart`

**Before**:
```dart
response = await http.post(
  uri,
  headers: const {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  },
  body: jsonEncode(body),
);
```

**After**:
```dart
final response = await Supabase.instance.client.functions.invoke(
  functionName,
  body: body,
).timeout(_requestTimeout);
```

### Why This Works
The `functions.invoke()` method automatically:
- Extracts the function name from the URI
- Handles JWT authentication using the current user's session token or the anon key
- Properly formats the request
- Returns the response as a Map

This eliminates the 401 Unauthorized errors because Supabase's client library knows how to properly authenticate with Edge Functions.

## Files Modified
1. `lib/services/passkey_auth_service.dart` - Updated `_postJson()` method to use `functions.invoke()`
2. `supabase/functions/passkeys-registration-finish/index.ts` - Made authorization optional
3. `supabase/functions/passkeys-authentication-finish/index.ts` - Made authorization optional

## Testing
After deploying these changes:

1. Rebuild the app:
   ```bash
   flutter pub get
   flutter run
   ```

2. Navigate to Settings → Passkey

3. Click "Add Passkey"

4. The passkey enrollment should now work without the 401 error

## Important Notes

### Current Implementation
The Edge Functions are still using basic implementations that:
- Generate valid WebAuthn challenges
- Accept any attestation/assertion (no verification)
- Return mock session tokens

This is suitable for development/testing.

### Production Considerations
For production, you should:
1. Implement proper WebAuthn verification using `@simplewebauthn/server`
2. Store passkey credentials in a database
3. Implement proper challenge storage and verification
4. Add comprehensive error handling
5. Implement credential rotation and revocation

See `PASSKEY_IMPLEMENTATION_GUIDE.md` for detailed production implementation steps.

## Deployment Steps

1. Deploy the updated Edge Functions:
   ```bash
   supabase functions deploy
   ```

2. Rebuild the app:
   ```bash
   flutter pub get
   flutter run
   ```

3. Test passkey enrollment in the app

## Troubleshooting

If you still see errors:

1. Check that all Edge Functions are deployed:
   ```bash
   supabase functions list
   ```

2. Verify the app config is set correctly:
   ```sql
   SELECT config_key, config_value FROM app_config 
   WHERE config_key LIKE 'auth.passkeys.%';
   ```

3. Check the app logs for detailed error messages

4. Verify the Supabase project URL and anon key are correct in the app

