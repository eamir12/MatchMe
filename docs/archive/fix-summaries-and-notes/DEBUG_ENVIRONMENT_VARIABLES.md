# Debug Environment Variables

## The Issue

The RP ID is still `vazkmvrbshxwyodentng.supabase.co` instead of `localhost`, which means the environment variables might not be set correctly in Supabase.

## How to Check

### Step 1: Redeploy Functions

I've added debug logging to the Edge Functions. Redeploy them:

```bash
supabase functions deploy passkeys-registration-start passkeys-authentication-start
```

### Step 2: Test Passkey Creation

1. Open the app
2. Go to Settings
3. Click "Add Passkey"

### Step 3: Check Edge Function Logs

In Supabase Dashboard:

1. Go to **Edge Functions**
2. Click on **passkeys-registration-start**
3. Go to **Logs** tab
4. Look for these lines:

```
[passkeys-registration-start] PASSKEY_DEVELOPMENT_MODE env var: true
[passkeys-registration-start] isDevelopmentMode: true
[passkeys-registration-start] PASSKEY_DEVELOPMENT_RP_ID env var: localhost
[passkeys-registration-start] Development mode enabled, using RP ID: localhost
```

### What Each Log Means

| Log | Meaning |
|-----|---------|
| `PASSKEY_DEVELOPMENT_MODE env var: true` | Environment variable is set correctly |
| `isDevelopmentMode: true` | The check `=== "true"` passed |
| `PASSKEY_DEVELOPMENT_RP_ID env var: localhost` | Development RP ID is set |
| `Development mode enabled, using RP ID: localhost` | Development mode is active |

## If You See Different Values

### If `PASSKEY_DEVELOPMENT_MODE env var: undefined`

**Problem:** Environment variable not set

**Solution:**
1. Go to Supabase Dashboard
2. Go to **Edge Functions**
3. Click on **passkeys-registration-start**
4. Click **Settings** (gear icon)
5. Scroll to **Environment Variables**
6. Add: `PASSKEY_DEVELOPMENT_MODE = true`
7. Click **Save**
8. Redeploy: `supabase functions deploy passkeys-registration-start`

### If `isDevelopmentMode: false`

**Problem:** Environment variable is set but not to `"true"`

**Solution:**
1. Check the value is exactly: `true` (not `True`, `TRUE`, or `"true"`)
2. Update if needed
3. Redeploy

### If `PASSKEY_DEVELOPMENT_RP_ID env var: undefined`

**Problem:** Development RP ID not set

**Solution:**
1. Go to Supabase Dashboard
2. Go to **Edge Functions**
3. Click on **passkeys-registration-start**
4. Click **Settings**
5. Add: `PASSKEY_DEVELOPMENT_RP_ID = localhost`
6. Click **Save**
7. Redeploy

## Complete Environment Variables Checklist

For each of these functions:
- passkeys-registration-start
- passkeys-registration-finish
- passkeys-authentication-start
- passkeys-authentication-finish

Set these environment variables:

| Key | Value |
|-----|-------|
| `PASSKEY_DEVELOPMENT_MODE` | `true` |
| `PASSKEY_DEVELOPMENT_RP_ID` | `localhost` |

## After Setting Environment Variables

1. Redeploy all functions:
   ```bash
   supabase functions deploy
   ```

2. Rebuild Flutter app:
   ```bash
   flutter clean && flutter pub get && flutter run
   ```

3. Test passkey creation again

4. Check logs for:
   ```
   [passkeys-registration-start] Development mode enabled, using RP ID: localhost
   ```

## Alternative: Check via Supabase CLI

You can also check environment variables via CLI:

```bash
supabase functions describe passkeys-registration-start
```

Look for the `env` section showing your variables.

## If Still Not Working

1. **Verify database config:**
   ```sql
   SELECT config_key, config_value FROM app_config 
   WHERE config_key LIKE 'auth.passkeys%';
   ```

2. **Check app logs:**
   ```
   [Passkey] Getting registration endpoints
   [Passkey] Start registration endpoint: ...
   ```

3. **Check Edge Function logs:**
   - Go to Supabase Dashboard
   - Edge Functions → passkeys-registration-start → Logs
   - Look for environment variable values

4. **Verify app config service:**
   - The app should read development mode from database
   - Then pass it to Edge Functions via environment variables

## Debug Flow

```
App Config Service
    ↓
Reads: auth.passkeys.development_mode = "true"
    ↓
Parses: "true" → true (removes quotes)
    ↓
Calls Edge Function
    ↓
Edge Function checks: PASSKEY_DEVELOPMENT_MODE env var
    ↓
If true: Uses localhost as RP ID
    ↓
Android accepts localhost
    ↓
Passkey creation succeeds
```

## Next Steps

1. Check Edge Function logs
2. Verify environment variables are set
3. Redeploy functions if needed
4. Rebuild Flutter app
5. Test passkey creation again

---

**Time to debug:** 5 minutes
**Difficulty:** Easy
**Result:** Identify why development mode isn't working
