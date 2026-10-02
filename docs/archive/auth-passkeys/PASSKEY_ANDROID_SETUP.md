# Android Passkey Setup Guide

## Current Issue

When trying to add a passkey on Android, you're getting this error:

```
RP ID cannot be validated.
```

This is an Android security requirement. The RP ID (Relying Party ID) must be associated with your app's domain.

## Solutions

### Option 1: Development Mode (Quick Testing)

For development and testing, you can enable development mode which uses a different RP ID that doesn't require domain association.

**Steps:**

1. Update the `app_config` table in Supabase:

```sql
UPDATE app_config 
SET config_value = 'true' 
WHERE config_key = 'auth.passkeys.development_mode';

UPDATE app_config 
SET config_value = 'localhost' 
WHERE config_key = 'auth.passkeys.development_rp_id';
```

2. Set environment variables for your Edge Functions:

```bash
PASSKEY_DEVELOPMENT_MODE=true
PASSKEY_DEVELOPMENT_RP_ID=localhost
```

3. Redeploy the Edge Functions:

```bash
supabase functions deploy passkeys-registration-start
supabase functions deploy passkeys-registration-finish
supabase functions deploy passkeys-authentication-start
supabase functions deploy passkeys-authentication-finish
```

4. Run the app and try adding a passkey again.

**Note:** This is for development only. For production, use Option 2.

### Option 2: Production Setup (Domain Association)

For production, you need to set up Android App Links to associate your app with your domain.

**Steps:**

1. **Generate your app's signing certificate SHA256 fingerprint:**

```bash
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
```

Look for the `SHA256:` line.

2. **Create a Digital Asset Links file:**

Create a file at: `https://your-domain.com/.well-known/assetlinks.json`

```json
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.example.matchme",
      "sha256_cert_fingerprints": [
        "YOUR_SHA256_FINGERPRINT_HERE"
      ]
    }
  }
]
```

3. **Update your RP ID in the database:**

```sql
UPDATE app_config 
SET config_value = 'your-domain.com' 
WHERE config_key = 'auth.passkeys.relying_party_id';

UPDATE app_config 
SET config_value = 'false' 
WHERE config_key = 'auth.passkeys.development_mode';
```

4. **Redeploy Edge Functions** (if you changed environment variables)

5. **Test on a real device** (emulators may not validate domain association properly)

### Option 3: Test on iOS

iOS doesn't have the same domain association requirement. You can test the passkey flow on iOS without any additional setup.

## Debugging

To see detailed logs of what's happening:

1. Run the app with: `flutter run`
2. Watch the console for logs starting with `[Passkey]`, `[PasskeyClient]`, and `[Settings]`
3. The logs will show exactly where the error occurs

## Environment Variables for Edge Functions

Set these in your Supabase project settings:

```
PASSKEY_RP_ID=your-domain.com (or localhost for dev)
PASSKEY_DEVELOPMENT_MODE=true/false
PASSKEY_DEVELOPMENT_RP_ID=localhost
```

## References

- [Android App Links Documentation](https://developer.android.com/training/app-links)
- [Digital Asset Links Format](https://developers.google.com/digital-asset-links/v1/getting-started)
- [WebAuthn RP ID Specification](https://www.w3.org/TR/webauthn-2/#rp-id)
