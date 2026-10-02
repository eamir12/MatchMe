# Correct SQL for Development Mode

## The Issue

The `config_value` column in the `app_config` table stores JSON values, not plain strings.

## Correct SQL

Run this in Supabase SQL Editor:

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

## Explanation

- `'"true"'::jsonb` - Converts the string `"true"` to JSONB format
- `'"localhost"'::jsonb` - Converts the string `"localhost"` to JSONB format
- The `::jsonb` cast tells PostgreSQL to treat it as JSON

## Expected Output

After running the SQL, you should see:

```
config_key                              | config_value
auth.passkeys.development_mode          | "true"
auth.passkeys.development_rp_id         | "localhost"
```

Note the quotes around the values - that's the JSON format.

## If Values Don't Exist Yet

If the config keys don't exist, insert them instead:

```sql
-- Insert development mode flag
INSERT INTO app_config (config_key, config_value, config_type, description)
VALUES (
  'auth.passkeys.development_mode',
  '"true"'::jsonb,
  'boolean',
  'Enable development mode for passkey testing'
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '"true"'::jsonb;

-- Insert development RP ID
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

## Next Steps

After running the correct SQL:

1. Set environment variables in Supabase Edge Functions
2. Redeploy Edge Functions
3. Rebuild Flutter app
4. Test passkey creation

See `ENABLE_DEVELOPMENT_MODE.md` for the complete steps.
