# Fixed Development Mode Setup

## The Issue

The `config_value` column stores JSON, not plain strings. The error was:
```
ERROR: 22P02: invalid input syntax for type json
Token "localhost" is invalid.
```

## The Solution

Use the correct JSON format with `::jsonb` cast.

## Correct SQL to Run

Copy and paste this into Supabase SQL Editor:

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

## What to Expect

After running the SQL, you should see:

```
config_key                              | config_value
auth.passkeys.development_mode          | "true"
auth.passkeys.development_rp_id         | "localhost"
```

**Note:** The quotes around `"true"` and `"localhost"` are part of the JSON format. This is correct.

## Why This Works

- `'"true"'::jsonb` - The outer single quotes are SQL string delimiters, the inner double quotes are JSON string delimiters
- `::jsonb` - PostgreSQL type cast to JSONB format
- Result: A JSON string value that the app config service can read

## Next Steps

1. ✅ Run the SQL above
2. Set environment variables in Supabase Edge Functions (see `ENABLE_DEVELOPMENT_MODE.md`)
3. Redeploy Edge Functions
4. Rebuild Flutter app
5. Test passkey creation

## If You Get an Error

### Error: "config_key does not exist"

The keys might not exist yet. Run this instead:

```sql
-- Insert if not exists, update if exists
INSERT INTO app_config (config_key, config_value, config_type, description)
VALUES (
  'auth.passkeys.development_mode',
  '"true"'::jsonb,
  'boolean',
  'Enable development mode for passkey testing'
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '"true"'::jsonb;

INSERT INTO app_config (config_key, config_value, config_type, description)
VALUES (
  'auth.passkeys.development_rp_id',
  '"localhost"'::jsonb,
  'string',
  'Development RP ID for testing passkeys without domain association'
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '"localhost"'::jsonb;

-- Verify
SELECT config_key, config_value FROM app_config 
WHERE config_key IN (
  'auth.passkeys.development_mode',
  'auth.passkeys.development_rp_id'
);
```

### Error: "invalid input syntax for type json"

Make sure you're using:
- `'"true"'::jsonb` (not `'true'::jsonb`)
- `'"localhost"'::jsonb` (not `'localhost'::jsonb`)

The double quotes inside the single quotes are important!

## Verification

After running the SQL, verify with:

```sql
SELECT config_key, config_value, config_type FROM app_config 
WHERE config_key LIKE 'auth.passkeys%'
ORDER BY config_key;
```

You should see:
- `auth.passkeys.development_mode` with value `"true"` and type `boolean`
- `auth.passkeys.development_rp_id` with value `"localhost"` and type `string`
- `auth.passkeys.relying_party_id` with value `"vazkmvrbshxwyodentng.supabase.co"` and type `string`

## Continue Setup

Once the SQL runs successfully:

1. Go to `ENABLE_DEVELOPMENT_MODE.md` for the remaining steps
2. Set environment variables in Edge Functions
3. Redeploy Edge Functions
4. Rebuild Flutter app
5. Test passkey creation

---

**Time to fix:** 2 minutes
**Difficulty:** Easy
**Result:** Development mode enabled for passkey testing
