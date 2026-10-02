# Passkey Setup Guide for Android

## Problem
Android's Credential Manager API requires Digital Asset Links configuration to validate the RP ID. Without this, passkey registration fails with "RP ID cannot be validated."

## Solution: Set Up Digital Asset Links

### Step 1: Get Your App's Signing Certificate Fingerprint

For debug builds (development):
```bash
cd android
./gradlew signingReport
```

Look for the SHA256 fingerprint in the output. It will look like:
```
Variant: debug
Config: debug
Store: ~/.android/keystore
Alias: androiddebugkey
MD5: XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX
SHA1: XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX
SHA256: XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX
```

Copy the SHA256 value.

### Step 2: Create assetlinks.json

Create a file at `.well-known/assetlinks.json` in your web server's root directory with this content:

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

Replace `YOUR_SHA256_FINGERPRINT_HERE` with the SHA256 fingerprint from Step 1.

### Step 3: Host assetlinks.json

Upload the `assetlinks.json` file to your domain at:
```
https://yourdomain.com/.well-known/assetlinks.json
```

For testing with Supabase, you would need to:
1. Create a custom domain or subdomain
2. Point it to your Supabase project
3. Host the assetlinks.json file there

### Step 4: Update RP ID Configuration

Once Digital Asset Links is set up, update the passkey configuration:

```sql
UPDATE app_config 
SET config_value = '"yourdomain.com"'::jsonb
WHERE config_key = 'auth.passkeys.development_rp_id';

UPDATE app_config 
SET config_value = 'false'::jsonb
WHERE config_key = 'auth.passkeys.development_mode';
```

### Step 5: Test

Rebuild and test passkey registration:
```bash
flutter clean
flutter pub get
flutter run
```

## Alternative: Use Production Domain

If you have a production domain already set up with Digital Asset Links, you can use that for testing by:

1. Setting the RP ID to your production domain
2. Ensuring Digital Asset Links is properly configured
3. Using the same signing certificate for your debug build (or adding the debug certificate to assetlinks.json)

## Troubleshooting

If you still get "RP ID cannot be validated":

1. Verify assetlinks.json is accessible at `https://yourdomain.com/.well-known/assetlinks.json`
2. Verify the JSON is valid (use a JSON validator)
3. Verify the SHA256 fingerprint matches your app's signing certificate
4. Wait a few minutes for Android to cache the Digital Asset Links
5. Clear app data and try again: `adb shell pm clear com.example.matchme`

## For Development Without Domain Setup

If you don't have a domain set up yet, you can:

1. Use a temporary domain service (e.g., ngrok, localtunnel)
2. Set up a local development server with proper HTTPS
3. Configure Digital Asset Links on that domain
4. Use that domain as the RP ID

This is the most reliable way to test passkeys during development.
