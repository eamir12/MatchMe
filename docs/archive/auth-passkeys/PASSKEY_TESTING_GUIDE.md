# Passkey Testing Guide - Development Mode

## Current Status

The passkey system is working perfectly! The logs show:
- ✅ Settings screen calls startRegistration
- ✅ Edge Function generates challenge correctly
- ✅ Challenge is Base64URL encoded properly
- ✅ Public key options are formatted correctly
- ✅ Native client receives options and creates RegisterRequestType
- ❌ Android credential manager rejects RP ID: `vazkmvrbshxwyodentng.supabase.co`

The only issue is Android's security requirement that the RP ID must be associated with your app's domain.

## Quick Fix: Enable Development Mode

### Step 1: Apply the Migration

Run this migration in your Supabase project:

```sql
-- Enable development mode for passkey testing
UPDATE app_config 
SET config_value = 'true' 
WHERE config_key = 'auth.passkeys.development_mode';

UPDATE app_config 
SET config_value = 'localhost' 
WHERE config_key = 'auth.passkeys.development_rp_id';
```

Or use the migration file:
```bash
supabase migration up
```

### Step 2: Set Environment Variables for Edge Functions

In your Supabase project dashboard:

1. Go to **Edge Functions** → **Settings** (or your function settings)
2. Add these environment variables:

```
PASSKEY_DEVELOPMENT_MODE=true
PASSKEY_DEVELOPMENT_RP_ID=localhost
```

### Step 3: Redeploy Edge Functions

```bash
supabase functions deploy passkeys-registration-start
supabase functions deploy passkeys-registration-finish
supabase functions deploy passkeys-authentication-start
supabase functions deploy passkeys-authentication-finish
```

Or redeploy all at once:
```bash
supabase functions deploy
```

### Step 4: Rebuild and Test

```bash
flutter clean
flutter pub get
flutter run
```

Then try adding a passkey again. You should now see:
```
[passkeys-registration-start] Development mode enabled, using RP ID: localhost
```

## Expected Behavior After Enabling Development Mode

When you click "Add Passkey":

1. Settings screen logs show the flow starting
2. Edge Function logs show development mode is enabled
3. Android credential manager should accept `localhost` as RP ID
4. Device credential manager UI appears
5. You can create a passkey

## Logs to Watch For

**Success indicators:**
```
[Passkey] startRegistration called
[Passkey] Got response from startRegistration
[Passkey] Result has public key options: true
[PasskeyClient] RegisterRequestType created successfully
[PasskeyClient] Calling authenticator.register()
```

**Development mode confirmation:**
```
[passkeys-registration-start] Development mode enabled, using RP ID: localhost
```

## Troubleshooting

### Still getting "RP ID cannot be validated"

1. Check that environment variables are set correctly in Supabase
2. Verify the migration was applied:
   ```sql
   SELECT config_key, config_value FROM app_config 
   WHERE config_key LIKE 'auth.passkeys%';
   ```
3. Make sure you redeployed the Edge Functions after setting env vars
4. Rebuild the Flutter app: `flutter clean && flutter pub get && flutter run`

### Logs not showing development mode message

1. Check Edge Function logs in Supabase dashboard
2. Verify environment variables are actually set
3. Try redeploying the functions

## Next Steps: Production Setup

Once testing is complete, for production you'll need to:

1. Set up Android App Links with Digital Asset Links
2. Update RP ID to your actual domain
3. Disable development mode
4. Redeploy Edge Functions

See `PASSKEY_ANDROID_SETUP.md` for production setup instructions.

## Testing Checklist

- [ ] Migration applied
- [ ] Environment variables set in Supabase
- [ ] Edge Functions redeployed
- [ ] Flutter app rebuilt
- [ ] Logs show development mode enabled
- [ ] Credential manager UI appears
- [ ] Passkey created successfully
- [ ] Passkey appears in settings

## Questions?

Check the logs! The enhanced logging system now shows:
- Every step of the passkey flow
- Exact error messages with types
- Request/response data
- Development mode status

All logs are prefixed with `[Passkey]`, `[PasskeyClient]`, or `[Settings]` for easy filtering.
