# Passkey System Fixes

## Issues Fixed

### 1. Duplicate "Current sign-in method" Box
**Problem**: The settings screen was displaying the "Current sign-in method" box twice - once in the Passkey section and once in the Account Management section.

**Solution**: 
- Removed the redundant `_buildCurrentAuthMethodSummary()` method from the Account Management section
- Kept the more informative `_buildPasskeyContextSummary()` in the Passkey section, which provides context about whether the current session is using a passkey or another auth method
- Removed the unused `_buildCurrentAuthMethodSummary()` method entirely (lines 403-475 in settings_screen.dart)

**Files Modified**:
- `lib/screens/settings/settings_screen.dart` - Removed duplicate widget and unused method

### 2. Passkey Configuration Setup
**Problem**: The passkey system was showing "Needs server setup" because the runtime configuration values were empty in the database.

**Solution**:
- Created a new migration file to configure the passkey runtime settings
- Set `auth.passkeys.relying_party_id` to the Supabase project domain: `vazkmvrbshxwyodentng.supabase.co`
- Set `auth.passkeys.server_base_url` to the Supabase project URL: `https://vazkmvrbshxwyodentng.supabase.co`

**Files Created**:
- `supabase/migrations/20260403_configure_passkey_runtime.sql` - Migration to set passkey configuration

## How Passkey Configuration Works

The passkey system requires two configuration values in the `app_config` table:

1. **Relying Party ID** (`auth.passkeys.relying_party_id`)
   - The domain that will be used as the WebAuthn relying party
   - Must match the domain of the server URL
   - Example: `vazkmvrbshxwyodentng.supabase.co`

2. **Server Base URL** (`auth.passkeys.server_base_url`)
   - The HTTPS base URL where passkey registration and authentication requests are handled
   - Must be a valid HTTPS URL
   - Must have a host that matches or is a subdomain of the relying party ID
   - Example: `https://vazkmvrbshxwyodentng.supabase.co`

## Validation Rules

The passkey configuration is considered valid when:
- Both `relying_party_id` and `server_base_url` are non-empty
- `server_base_url` is a valid HTTPS URL with a non-empty host
- The host of `server_base_url` matches or is a subdomain of `relying_party_id`

## Next Steps

1. Run the migration to apply the passkey configuration:
   ```bash
   supabase db push
   ```

2. Verify the configuration was applied:
   ```sql
   SELECT config_key, config_value FROM app_config 
   WHERE config_key IN ('auth.passkeys.relying_party_id', 'auth.passkeys.server_base_url');
   ```

3. The settings screen should now show:
   - ✅ Passkey status as "Ready" (instead of "Setup Required")
   - ✅ Only one "Current sign-in method" box in the Passkey section
   - ✅ Users can now add passkeys to their account

## Testing

After applying the migration:
1. Navigate to Settings → Passkey
2. Verify the status shows "Ready" with a green checkmark
3. Click "Add Passkey" to test passkey enrollment
4. Verify the "Current sign-in method" box appears only once

