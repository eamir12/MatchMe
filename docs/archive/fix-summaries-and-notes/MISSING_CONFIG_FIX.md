# Missing Config Fix

## The Problem

The development mode config keys are **missing from the database**. You only have:
- `auth.passkeys.server_base_url`
- `auth.passkeys.relying_party_id`

But you're missing:
- `auth.passkeys.development_mode` ❌
- `auth.passkeys.development_rp_id` ❌

That's why development mode isn't working!

## The Solution

Run this SQL in Supabase SQL Editor:

```sql
-- Insert development mode configuration
INSERT INTO app_config (
  config_key, 
  config_value, 
  config_type, 
  category,
  description,
  is_user_configurable
)
VALUES (
  'auth.passkeys.development_mode',
  '"true"'::jsonb,
  'boolean',
  'auth',
  'Enable development mode for passkey testing',
  false
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '"true"'::jsonb;

INSERT INTO app_config (
  config_key, 
  config_value, 
  config_type, 
  category,
  description,
  is_user_configurable
)
VALUES (
  'auth.passkeys.development_rp_id',
  '"localhost"'::jsonb,
  'string',
  'auth',
  'Development RP ID for testing passkeys without domain association',
  false
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '"localhost"'::jsonb;

-- Verify
SELECT config_key, config_value FROM app_config 
WHERE config_key LIKE 'auth.passkeys%'
ORDER BY config_key;
```

## Expected Result

After running the SQL, you should see:

```
config_key                              | config_value
auth.passkeys.development_mode          | "true"
auth.passkeys.development_rp_id         | "localhost"
auth.passkeys.relying_party_id          | "vazkmvrbshxwyodentng.supabase.co"
auth.passkeys.server_base_url           | "https://vazkmvrbshxwyodentng.supabase.co"
```

## Why This Works

1. **App starts up**
2. **App config service loads config from database**
3. **Finds `auth.passkeys.development_mode = "true"`**
4. **Parses it: `"true"` → `true`**
5. **Calls `getPasskeysRelyingPartyId()`**
6. **Checks development mode flag**
7. **Returns `localhost` instead of production domain**
8. **Edge Functions receive `localhost` as RP ID**
9. **Android accepts `localhost` for testing**
10. **Passkey creation succeeds!**

## Next Steps

1. ✅ Run the SQL above
2. Verify the 4 config keys are in the database
3. Rebuild Flutter app: `flutter clean && flutter pub get && flutter run`
4. Test passkey creation
5. Check logs for: `Development mode enabled, using RP ID: localhost`

## Verification

After running the SQL, verify with:

```sql
SELECT config_key, config_value, config_type FROM app_config 
WHERE config_key LIKE 'auth.passkeys%'
ORDER BY config_key;
```

Should show 4 rows:
1. `auth.passkeys.development_mode` = `"true"` (boolean)
2. `auth.passkeys.development_rp_id` = `"localhost"` (string)
3. `auth.passkeys.relying_party_id` = `"vazkmvrbshxwyodentng.supabase.co"` (string)
4. `auth.passkeys.server_base_url` = `"https://vazkmvrbshxwyodentng.supabase.co"` (string)

---

**Time to fix:** 2 minutes
**Difficulty:** Easy
**Result:** Development mode configuration added to database
