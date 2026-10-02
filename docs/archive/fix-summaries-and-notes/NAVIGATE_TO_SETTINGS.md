# Navigate to Settings to See Logs

## What to Do

### Step 1: Rebuild the App

```bash
flutter clean
flutter pub get
flutter run
```

### Step 2: Navigate to Settings

1. Open the app
2. Go to **Settings** (bottom navigation or menu)
3. Scroll down to the **Passkey** section

### Step 3: Watch the Console

Look for these logs:

```
📋 [AppConfig] Initializing app configuration...
📋 [AppConfig] Loading config from database...
📋 [AppConfig] Got X config entries from database
📋 [AppConfig] Loaded: auth.passkeys.development_mode = ...
📋 [AppConfig] Loaded: auth.passkeys.development_rp_id = ...
📋 [AppConfig] Loaded: auth.passkeys.relying_party_id = ...
📋 [AppConfig] Loaded: auth.passkeys.server_base_url = ...
📋 [AppConfig] Config cache populated with X entries
📋 [AppConfig] getPasskeysRuntimeConfig:
📋 [AppConfig]   relyingPartyId: "..."
📋 [AppConfig]   serverBaseUrl: "..."
📋 [AppConfig]   hasRequiredFields: ...
📋 [AppConfig]   hasValidHttpsServerBaseUrl: ...
📋 [AppConfig]   hasCompatibleRelyingPartyId: ...
📋 [AppConfig]   isValid: ...
```

### Step 4: Analyze the Logs

**Look for:**

1. **Are passkey config entries being loaded?**
   - Should see: `Loaded: auth.passkeys.development_mode = ...`
   - Should see: `Loaded: auth.passkeys.relying_party_id = ...`
   - Should see: `Loaded: auth.passkeys.server_base_url = ...`

2. **What are the values?**
   - `development_mode` should be: `true`
   - `development_rp_id` should be: `localhost`
   - `relying_party_id` should be: `vazkmvrbshxwyodentng.supabase.co`
   - `server_base_url` should be: `https://vazkmvrbshxwyodentng.supabase.co`

3. **Is the config valid?**
   - Should see: `isValid: true`
   - If `false`, check which validation failed

### Step 5: Report the Logs

Copy the relevant logs and share them so we can see:
- What values are being loaded
- Which validation is failing
- Why the "Needs server setup" message is showing

## Expected Logs

If everything is working:

```
📋 [AppConfig] Initializing app configuration...
📋 [AppConfig] Loading config from database...
📋 [AppConfig] Got 9 config entries from database
📋 [AppConfig] Loaded: auth.passkeys.development_mode = true
📋 [AppConfig] Loaded: auth.passkeys.development_rp_id = localhost
📋 [AppConfig] Loaded: auth.passkeys.relying_party_id = vazkmvrbshxwyodentng.supabase.co
📋 [AppConfig] Loaded: auth.passkeys.server_base_url = https://vazkmvrbshxwyodentng.supabase.co
📋 [AppConfig] Config cache populated with 9 entries
📋 [AppConfig] getPasskeysRuntimeConfig:
📋 [AppConfig]   relyingPartyId: "vazkmvrbshxwyodentng.supabase.co"
📋 [AppConfig]   serverBaseUrl: "https://vazkmvrbshxwyodentng.supabase.co"
📋 [AppConfig]   hasRequiredFields: true
📋 [AppConfig]   hasValidHttpsServerBaseUrl: true
📋 [AppConfig]   hasCompatibleRelyingPartyId: true
📋 [AppConfig]   isValid: true
```

Then the "Add Passkey" button should be enabled!

## If Logs Don't Appear

1. Make sure you're looking at the Flutter console (not Android logs)
2. Filter for `[AppConfig]` prefix
3. Scroll up to see initialization logs
4. Check that you navigated to Settings

## Next Steps

1. Rebuild app
2. Navigate to Settings
3. Share the logs you see
4. We'll diagnose the issue from there
