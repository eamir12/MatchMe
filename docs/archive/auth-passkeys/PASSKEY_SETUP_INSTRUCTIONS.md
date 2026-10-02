# Passkey Development Mode Setup - Step by Step

## What's Been Done

✅ **Logging System Enhanced**
- All passkey operations now log to both stdout and stderr
- Logs are prefixed with `[Passkey]`, `[PasskeyClient]`, or `[Settings]`
- Logs appear immediately in the Flutter console

✅ **Development Mode Support Added**
- Edge Functions now support development mode
- App config service checks for development mode flag
- When enabled, uses `localhost` as RP ID instead of your domain

✅ **Root Cause Identified**
- Android requires RP ID to match app domain or be associated via Digital Asset Links
- Development mode bypasses this for testing

## Setup Instructions

### 1. Apply Database Migration

Run this SQL in your Supabase SQL Editor:

```sql
-- Enable development mode for passkey testing
UPDATE app_config 
SET config_value = '"true"'::jsonb
WHERE config_key = 'auth.passkeys.development_mode';

UPDATE app_config 
SET config_value = '"localhost"'::jsonb
WHERE config_key = 'auth.passkeys.development_rp_id';

-- Verify the changes
SELECT config_key, config_value FROM app_config 
WHERE config_key IN (
  'auth.passkeys.development_mode',
  'auth.passkeys.development_rp_id',
  'auth.passkeys.relying_party_id'
);
```

**Expected output:**
```
config_key                              | config_value
auth.passkeys.development_mode          | "true"
auth.passkeys.development_rp_id         | "localhost"
auth.passkeys.relying_party_id          | "vazkmvrbshxwyodentng.supabase.co"
```

### 2. Set Environment Variables for Edge Functions

In Supabase Dashboard:

1. Go to **Edge Functions**
2. Click on each function:
   - `passkeys-registration-start`
   - `passkeys-registration-finish`
   - `passkeys-authentication-start`
   - `passkeys-authentication-finish`

3. For each function, go to **Settings** and add these environment variables:

```
PASSKEY_DEVELOPMENT_MODE=true
PASSKEY_DEVELOPMENT_RP_ID=localhost
```

**Or** if your Supabase project has a way to set global environment variables, set them there.

### 3. Redeploy Edge Functions

From your terminal:

```bash
cd supabase/functions

# Redeploy all passkey functions
supabase functions deploy passkeys-registration-start
supabase functions deploy passkeys-registration-finish
supabase functions deploy passkeys-authentication-start
supabase functions deploy passkeys-authentication-finish
```

Or redeploy all functions at once:
```bash
supabase functions deploy
```

### 4. Rebuild Flutter App

```bash
flutter clean
flutter pub get
flutter run
```

### 5. Test Adding a Passkey

1. Open the app
2. Go to Settings
3. Click "Add Passkey"
4. Watch the console for logs

**You should see:**
```
[Settings] Starting passkey enrollment
[Passkey] startRegistration called
[Passkey] Getting registration endpoints
[Passkey] Calling _postJson for registration start
[Passkey] Calling function: passkeys-registration-start
[Passkey] Response status: 200
[Passkey] Got response from startRegistration
[Settings] Got challenge, has public key options: true
[Settings] Getting registration attestation from device
[PasskeyClient] getRegistrationAttestation called
[PasskeyClient] Creating RegisterRequestType from JSON
[PasskeyClient] RegisterRequestType created successfully
[PasskeyClient] Calling authenticator.register()
```

Then the Android credential manager UI should appear.

## Verification Checklist

- [ ] SQL migration executed successfully
- [ ] Environment variables set in Supabase
- [ ] Edge Functions redeployed
- [ ] Flutter app rebuilt with `flutter clean`
- [ ] Console shows `[Passkey]` logs
- [ ] Console shows development mode message from Edge Function
- [ ] Android credential manager UI appears
- [ ] Passkey created successfully

## If It Still Doesn't Work

### Check 1: Verify Database Changes

```sql
SELECT config_key, config_value FROM app_config 
WHERE config_key LIKE 'auth.passkeys%' 
ORDER BY config_key;
```

Should show:
- `auth.passkeys.development_mode` = `"true"` (with quotes - that's JSON format)
- `auth.passkeys.development_rp_id` = `"localhost"` (with quotes - that's JSON format)

### Check 2: Verify Edge Function Environment Variables

In Supabase Dashboard, click on each function and check Settings tab.

### Check 3: Check Edge Function Logs

In Supabase Dashboard:
1. Go to Edge Functions
2. Click on `passkeys-registration-start`
3. Go to **Logs** tab
4. Look for: `Development mode enabled, using RP ID: localhost`

If you see this, the environment variables are set correctly.

### Check 4: Rebuild Everything

```bash
flutter clean
flutter pub get
flutter run
```

### Check 5: Check Flutter Logs

Run with verbose logging:
```bash
flutter run -v 2>&1 | grep -i "passkey\|rp id"
```

## What Happens Next

Once you successfully create a passkey in development mode:

1. The passkey is stored on your device
2. You can use it to sign in
3. The system is ready for production setup

For production, you'll need to:
1. Set up Android App Links with Digital Asset Links
2. Update RP ID to your actual domain
3. Disable development mode
4. Redeploy Edge Functions

See `PASSKEY_ANDROID_SETUP.md` for production instructions.

## Files Modified

- `lib/services/app_config_service.dart` - Added development mode support
- `lib/services/passkey_auth_service.dart` - Enhanced logging
- `lib/services/passkey_client_service_native.dart` - Enhanced logging
- `lib/screens/settings/settings_screen.dart` - Enhanced logging
- `supabase/functions/passkeys-registration-start/index.ts` - Added development mode
- `supabase/functions/passkeys-authentication-start/index.ts` - Added development mode
- `supabase/migrations/20260403000000_add_passkey_development_rp_id.sql` - New migration
- `supabase/migrations/20260403100000_enable_passkey_development_mode.sql` - Enable dev mode

## Questions?

The enhanced logging system will show you exactly what's happening at each step. Look for:
- `[Passkey]` - Main passkey service logs
- `[PasskeyClient]` - Native client logs
- `[Settings]` - Settings screen logs
- `[passkeys-*]` - Edge Function logs (in Supabase dashboard)

All errors include the error type and details, making debugging straightforward.
