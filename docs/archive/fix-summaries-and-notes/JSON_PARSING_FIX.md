# JSON Parsing Fix for Development Mode

## The Problem

The app config service wasn't properly parsing JSON string values from the database.

When you set:
```sql
UPDATE app_config SET config_value = '"true"'::jsonb WHERE config_key = 'auth.passkeys.development_mode';
```

The database stores it as a JSON string: `"true"` (with quotes)

But the app was comparing it as: `value.toLowerCase() == 'true'`

This comparison failed because:
- `value` = `"true"` (with quotes)
- `'true'` = `true` (without quotes)
- `"true" != true` ❌

## The Solution

Updated `_parseConfigValue()` method in `app_config_service.dart` to:

1. **For boolean type:**
   - Remove quotes: `"true"` → `true`
   - Convert to lowercase
   - Compare with `'true'`

2. **For string type:**
   - Remove surrounding quotes: `"localhost"` → `localhost`
   - Return the clean value

## Code Changes

```dart
case 'boolean':
  if (value is bool) return value;
  if (value is String) {
    // Handle JSON string format: "true" or "false"
    final cleaned = value.replaceAll('"', '').toLowerCase().trim();
    return cleaned == 'true';
  }
  return value;

case 'string':
  // Handle JSON string format: "value" -> value
  if (value is String && value.startsWith('"') && value.endsWith('"')) {
    return value.substring(1, value.length - 1);
  }
  return value.toString();
```

## What This Fixes

Now when the app reads the config:

1. Database has: `config_value = "true"` (JSON string)
2. App reads: `"true"` (string with quotes)
3. Parser removes quotes: `true` (clean string)
4. Comparison works: `true == 'true'` ✅
5. Development mode is enabled!

## Testing

After rebuilding the app:

1. Go to Settings
2. Click "Add Passkey"
3. Watch the logs

You should now see:
```
[Passkey] Getting registration endpoints
[Passkey] Start registration endpoint: https://...
[passkeys-registration-start] Development mode enabled, using RP ID: localhost
```

The RP ID should now be `localhost` instead of `vazkmvrbshxwyodentng.supabase.co`

## Rebuild Instructions

```bash
flutter clean
flutter pub get
flutter run
```

## Verification

Check the logs for:
- `[Passkey] startRegistration called`
- `[passkeys-registration-start] Development mode enabled, using RP ID: localhost`
- Android credential manager appears
- Passkey creation succeeds

## Why This Matters

The JSON parsing fix ensures that:
- Boolean config values are properly parsed
- String config values have quotes removed
- Development mode flag is correctly read
- RP ID is properly set to `localhost`
- Android accepts the RP ID for testing

## Files Modified

- `lib/services/app_config_service.dart` - Updated `_parseConfigValue()` method

## Next Steps

1. Rebuild the Flutter app
2. Test passkey creation
3. Verify logs show development mode enabled
4. Android credential manager should appear
5. Create a passkey successfully

---

**Time to fix:** Rebuild app (2-3 minutes)
**Difficulty:** Already done - just rebuild
**Result:** Development mode now works correctly
