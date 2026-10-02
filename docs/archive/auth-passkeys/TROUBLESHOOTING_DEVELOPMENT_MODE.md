# Troubleshooting Development Mode

## Symptom: RP ID Still Shows Production Domain

**Log shows:**
```
rp: {name: MatchMe, id: vazkmvrbshxwyodentng.supabase.co}
```

**Expected:**
```
rp: {name: MatchMe, id: localhost}
```

## Root Causes & Solutions

### Cause 1: Environment Variables Not Set in Edge Functions

**Check:**
1. Go to Supabase Dashboard
2. Edge Functions → passkeys-registration-start → Settings
3. Look for Environment Variables section

**If missing:**
1. Add `PASSKEY_DEVELOPMENT_MODE = true`
2. Add `PASSKEY_DEVELOPMENT_RP_ID = localhost`
3. Click Save
4. Repeat for all 4 passkey functions

**Then:**
```bash
supabase functions deploy
flutter clean && flutter pub get && flutter run
```

### Cause 2: Environment Variables Set But Not Redeployed

**Check:**
- Did you redeploy after setting environment variables?

**Solution:**
```bash
supabase functions deploy passkeys-registration-start passkeys-authentication-start
```

### Cause 3: Database Config Not Updated

**Check:**
```sql
SELECT config_key, config_value FROM app_config 
WHERE config_key LIKE 'auth.passkeys%';
```

**Should show:**
```
auth.passkeys.development_mode          | "true"
auth.passkeys.development_rp_id         | "localhost"
auth.passkeys.relying_party_id          | "vazkmvrbshxwyodentng.supabase.co"
```

**If missing:**
```sql
UPDATE app_config 
SET config_value = '"true"'::jsonb
WHERE config_key = 'auth.passkeys.development_mode';

UPDATE app_config 
SET config_value = '"localhost"'::jsonb
WHERE config_key = 'auth.passkeys.development_rp_id';
```

### Cause 4: App Config Service Not Parsing JSON Correctly

**Check:**
- Did you rebuild the app after the JSON parsing fix?

**Solution:**
```bash
flutter clean
flutter pub get
flutter run
```

### Cause 5: Cache Not Refreshed

**Check:**
- App config service caches for 5 minutes

**Solution:**
1. Restart the app
2. Or wait 5 minutes for cache to refresh

## Step-by-Step Verification

### Step 1: Verify Database Config

```sql
SELECT config_key, config_value, config_type FROM app_config 
WHERE config_key LIKE 'auth.passkeys%'
ORDER BY config_key;
```

**Expected output:**
```
auth.passkeys.development_mode          | "true"          | boolean
auth.passkeys.development_rp_id         | "localhost"     | string
auth.passkeys.relying_party_id          | "vazkmvrbshxwyodentng.supabase.co" | string
```

✅ If correct, move to Step 2
❌ If incorrect, run the SQL above to fix

### Step 2: Verify Environment Variables in Edge Functions

For each function (passkeys-registration-start, etc.):

1. Go to Supabase Dashboard
2. Edge Functions → [function name] → Settings
3. Check Environment Variables section

**Should show:**
```
PASSKEY_DEVELOPMENT_MODE = true
PASSKEY_DEVELOPMENT_RP_ID = localhost
```

✅ If correct, move to Step 3
❌ If missing, add them and save

### Step 3: Redeploy Functions

```bash
supabase functions deploy
```

Wait for all functions to show ✓

✅ If successful, move to Step 4
❌ If error, check Supabase status

### Step 4: Rebuild Flutter App

```bash
flutter clean
flutter pub get
flutter run
```

✅ If successful, move to Step 5
❌ If error, check Flutter logs

### Step 5: Test Passkey Creation

1. Open app
2. Go to Settings
3. Click "Add Passkey"
4. Watch console

**Expected logs:**
```
[Passkey] startRegistration called
[passkeys-registration-start] PASSKEY_DEVELOPMENT_MODE env var: true
[passkeys-registration-start] isDevelopmentMode: true
[passkeys-registration-start] Development mode enabled, using RP ID: localhost
[PasskeyClient] RegisterRequestType created successfully
```

✅ If you see these logs, development mode is working
❌ If not, check Edge Function logs in Supabase dashboard

### Step 6: Check Edge Function Logs

1. Go to Supabase Dashboard
2. Edge Functions → passkeys-registration-start → Logs
3. Look for the most recent invocation
4. Check for environment variable values

**If you see:**
```
PASSKEY_DEVELOPMENT_MODE env var: undefined
```

→ Environment variables not set, go back to Step 2

**If you see:**
```
PASSKEY_DEVELOPMENT_MODE env var: true
isDevelopmentMode: true
Development mode enabled, using RP ID: localhost
```

→ Development mode is working! Android should accept the RP ID

## Common Issues & Fixes

### Issue: "RP ID cannot be validated" Still Appears

**Cause:** Development mode not enabled

**Fix:**
1. Check all 6 steps above
2. Verify environment variables are set
3. Verify functions are redeployed
4. Verify app is rebuilt

### Issue: No Logs Showing Development Mode

**Cause:** Functions not redeployed or app not rebuilt

**Fix:**
```bash
supabase functions deploy
flutter clean && flutter pub get && flutter run
```

### Issue: Logs Show `isDevelopmentMode: false`

**Cause:** Environment variable not set to exactly `true`

**Fix:**
1. Check value is: `true` (not `True`, `TRUE`, `"true"`)
2. Update if needed
3. Redeploy

### Issue: Logs Show `PASSKEY_DEVELOPMENT_RP_ID env var: undefined`

**Cause:** Environment variable not set

**Fix:**
1. Go to Edge Function Settings
2. Add: `PASSKEY_DEVELOPMENT_RP_ID = localhost`
3. Save
4. Redeploy

## Quick Checklist

- [ ] Database config updated (SQL run)
- [ ] Environment variables set in all 4 functions
- [ ] Functions redeployed (`supabase functions deploy`)
- [ ] Flutter app rebuilt (`flutter clean && flutter pub get && flutter run`)
- [ ] Logs show development mode enabled
- [ ] Android credential manager appears
- [ ] Passkey created successfully

## If Still Stuck

1. **Check Edge Function logs:**
   - Supabase Dashboard → Edge Functions → [function] → Logs
   - Look for environment variable values

2. **Check Flutter logs:**
   - Look for `[Passkey]` prefix
   - Check for error messages

3. **Verify database:**
   ```sql
   SELECT * FROM app_config WHERE config_key LIKE 'auth.passkeys%';
   ```

4. **Restart everything:**
   ```bash
   # Stop the app
   # Redeploy functions
   supabase functions deploy
   # Rebuild app
   flutter clean && flutter pub get && flutter run
   ```

## Expected Timeline

- Database config: 1 minute
- Set environment variables: 2 minutes
- Redeploy functions: 2 minutes
- Rebuild app: 3 minutes
- Test: 1 minute
- **Total: ~10 minutes**

---

**Status:** Debugging development mode setup
**Next action:** Follow the 6-step verification process
