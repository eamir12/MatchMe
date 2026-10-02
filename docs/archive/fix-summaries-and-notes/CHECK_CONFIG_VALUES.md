# Check Configuration Values

## The Issue

The app is showing "Needs server setup" which means `PasskeysRuntimeConfig.isValid` is returning `false`.

This could be because:
1. RP ID is empty or null
2. Server URL is empty or null
3. Server URL is not HTTPS
4. RP ID doesn't match the server URL domain

## What to Do

### Step 1: Rebuild the App

```bash
flutter clean
flutter pub get
flutter run
```

### Step 2: Check the Logs

Look for these logs:

```
📋 [AppConfig] getPasskeysRuntimeConfig:
📋 [AppConfig]   relyingPartyId: "..."
📋 [AppConfig]   serverBaseUrl: "..."
📋 [AppConfig]   hasRequiredFields: ...
📋 [AppConfig]   hasValidHttpsServerBaseUrl: ...
📋 [AppConfig]   hasCompatibleRelyingPartyId: ...
📋 [AppConfig]   isValid: ...
```

### Step 3: Analyze the Results

**If `relyingPartyId` is empty:**
- Database value is not being read
- Check: `SELECT config_value FROM app_config WHERE config_key = 'auth.passkeys.relying_party_id'`

**If `serverBaseUrl` is empty:**
- Database value is not being read
- Check: `SELECT config_value FROM app_config WHERE config_key = 'auth.passkeys.server_base_url'`

**If `hasRequiredFields: false`:**
- One or both values are empty
- Check database values

**If `hasValidHttpsServerBaseUrl: false`:**
- Server URL is not HTTPS or not valid
- Should be: `https://vazkmvrbshxwyodentng.supabase.co`

**If `hasCompatibleRelyingPartyId: false`:**
- RP ID doesn't match server URL domain
- RP ID should be: `vazkmvrbshxwyodentng.supabase.co`
- Server URL should be: `https://vazkmvrbshxwyodentng.supabase.co`

**If `isValid: false`:**
- One of the above checks failed
- Look at which one is false

## Expected Values

```
relyingPartyId: "vazkmvrbshxwyodentng.supabase.co"
serverBaseUrl: "https://vazkmvrbshxwyodentng.supabase.co"
hasRequiredFields: true
hasValidHttpsServerBaseUrl: true
hasCompatibleRelyingPartyId: true
isValid: true
```

## If Values Are Wrong

### If RP ID is wrong:

```sql
UPDATE app_config 
SET config_value = '"vazkmvrbshxwyodentng.supabase.co"'::jsonb
WHERE config_key = 'auth.passkeys.relying_party_id';
```

### If Server URL is wrong:

```sql
UPDATE app_config 
SET config_value = '"https://vazkmvrbshxwyodentng.supabase.co"'::jsonb
WHERE config_key = 'auth.passkeys.server_base_url';
```

### Then:

1. Rebuild app: `flutter clean && flutter pub get && flutter run`
2. Check logs again
3. Should now show `isValid: true`

## Next Steps

1. Rebuild app
2. Check logs
3. Report which value is wrong
4. Fix the database value
5. Rebuild and test again
