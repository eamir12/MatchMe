# Enable Development Mode - Visual Guide

## Step 1: Run SQL in Supabase

1. Open Supabase Dashboard
2. Go to **SQL Editor**
3. Click **New Query**
4. Copy and paste this SQL:

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
  'auth.passkeys.development_rp_id'
);
```

5. Click **Run**
6. You should see:
   ```
   config_key                              | config_value
   auth.passkeys.development_mode          | "true"
   auth.passkeys.development_rp_id         | "localhost"
   ```

## Step 2: Set Environment Variables

### For Each Edge Function:

1. Go to **Edge Functions** in Supabase Dashboard
2. Click on `passkeys-registration-start`
3. Click **Settings** (gear icon)
4. Scroll to **Environment Variables**
5. Add these two variables:

| Key | Value |
|-----|-------|
| `PASSKEY_DEVELOPMENT_MODE` | `true` |
| `PASSKEY_DEVELOPMENT_RP_ID` | `localhost` |

6. Click **Save**

**Repeat for these functions:**
- `passkeys-registration-finish`
- `passkeys-authentication-start`
- `passkeys-authentication-finish`

### Visual Example:
```
Edge Functions
├── passkeys-registration-start
│   └── Settings
│       └── Environment Variables
│           ├── PASSKEY_DEVELOPMENT_MODE = true
│           └── PASSKEY_DEVELOPMENT_RP_ID = localhost
├── passkeys-registration-finish
│   └── Settings
│       └── Environment Variables
│           ├── PASSKEY_DEVELOPMENT_MODE = true
│           └── PASSKEY_DEVELOPMENT_RP_ID = localhost
├── passkeys-authentication-start
│   └── Settings
│       └── Environment Variables
│           ├── PASSKEY_DEVELOPMENT_MODE = true
│           └── PASSKEY_DEVELOPMENT_RP_ID = localhost
└── passkeys-authentication-finish
    └── Settings
        └── Environment Variables
            ├── PASSKEY_DEVELOPMENT_MODE = true
            └── PASSKEY_DEVELOPMENT_RP_ID = localhost
```

## Step 3: Redeploy Edge Functions

Open terminal and run:

```bash
# Navigate to your project
cd /path/to/MatchMe4

# Redeploy all functions
supabase functions deploy

# Or redeploy specific functions
supabase functions deploy passkeys-registration-start
supabase functions deploy passkeys-registration-finish
supabase functions deploy passkeys-authentication-start
supabase functions deploy passkeys-authentication-finish
```

Wait for deployment to complete. You should see:
```
✓ Function passkeys-registration-start deployed
✓ Function passkeys-registration-finish deployed
✓ Function passkeys-authentication-start deployed
✓ Function passkeys-authentication-finish deployed
```

## Step 4: Rebuild Flutter App

```bash
# Clean build
flutter clean

# Get dependencies
flutter pub get

# Run app
flutter run
```

## Step 5: Test

1. Open the app
2. Go to **Settings**
3. Scroll to **Passkeys** section
4. Click **Add Passkey**
5. Watch the console for logs

### Expected Console Output:

```
I/flutter ( 8036): [Settings] Starting passkey enrollment
I/flutter ( 8036): [Passkey] startRegistration called
I/flutter ( 8036): [Passkey] Current user ID: 35fe114e-eae5-49d6-9eba-8459617e7b82
I/flutter ( 8036): [Passkey] Current user email: eranamir12@gmail.com
I/flutter ( 8036): [Passkey] Getting registration endpoints
I/flutter ( 8036): [Passkey] Calling _postJson for registration start
I/flutter ( 8036): [Passkey] Response status: 200
I/flutter ( 8036): [Passkey] Got response from startRegistration
I/flutter ( 8036): [Settings] Got challenge, has public key options: true
I/flutter ( 8036): [PasskeyClient] getRegistrationAttestation called
I/flutter ( 8036): [PasskeyClient] Creating RegisterRequestType from JSON
I/flutter ( 8036): [PasskeyClient] RegisterRequestType created successfully
I/flutter ( 8036): [PasskeyClient] Calling authenticator.register()
```

### Then:
- Android credential manager UI appears
- You can create a passkey
- Success message shows

## Troubleshooting

### Problem: Still getting "RP ID cannot be validated"

**Check 1: Verify SQL ran**
```sql
SELECT config_key, config_value FROM app_config 
WHERE config_key LIKE 'auth.passkeys%';
```

Should show:
- `auth.passkeys.development_mode` = `true`
- `auth.passkeys.development_rp_id` = `localhost`

**Check 2: Verify environment variables**
- Go to each Edge Function → Settings
- Confirm both variables are set
- Values should be exactly: `true` and `localhost`

**Check 3: Verify functions redeployed**
```bash
supabase functions deploy
```

Wait for all functions to show ✓

**Check 4: Rebuild Flutter app**
```bash
flutter clean
flutter pub get
flutter run
```

### Problem: No logs showing

**Solution:**
```bash
flutter clean
flutter pub get
flutter run
```

Then look for `[Passkey]` prefix in console.

### Problem: Logs show but credential manager doesn't appear

**Check:**
1. Device has credential manager support
2. Development mode is actually enabled (check logs for "Development mode enabled")
3. RP ID is `localhost` (check logs)

## Verification Checklist

- [ ] SQL executed successfully
- [ ] All 4 functions have environment variables set
- [ ] All 4 functions redeployed
- [ ] Flutter app rebuilt with `flutter clean`
- [ ] Console shows `[Passkey]` logs
- [ ] Console shows development mode message
- [ ] Credential manager UI appears
- [ ] Passkey created successfully

## Success Indicators

✅ Console shows: `[Passkey] startRegistration called`
✅ Console shows: `[PasskeyClient] RegisterRequestType created successfully`
✅ Android credential manager UI appears
✅ You can create a passkey
✅ Passkey appears in settings

## Next Steps

Once passkey creation works:

1. **Test passkey sign-in** - Use the passkey to sign in
2. **Test on different devices** - Ensure it works across devices
3. **Plan production setup** - See `PASSKEY_ANDROID_SETUP.md`

## Questions?

Check the logs! The enhanced logging system shows:
- Every step of the flow
- Exact error messages
- Request/response data
- Development mode status

All logs are prefixed with `[Passkey]`, `[PasskeyClient]`, or `[Settings]`.

---

**Time to complete:** ~10 minutes
**Difficulty:** Easy
**Result:** Fully functional passkey system for testing
