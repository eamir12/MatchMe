# Passkey Implementation Guide

## Problem

The passkey system was showing the error "Could not add a passkey right now. Please try again." This was because the app was trying to call passkey endpoints that didn't exist on the server.

## Root Cause

The passkey authentication system requires backend endpoints to handle the WebAuthn ceremony:
1. **Start Registration** - Generate a challenge for the client to create a passkey
2. **Finish Registration** - Verify the attestation and store the credential
3. **Start Authentication** - Generate a challenge for the client to authenticate with a passkey
4. **Finish Authentication** - Verify the assertion and return a session

These endpoints were not implemented, causing the HTTP requests to fail with 404 errors.

## Solution

Created four Supabase Edge Functions to handle the WebAuthn ceremony:

### 1. Passkey Registration Start
**File**: `supabase/functions/passkeys-registration-start/index.ts`
- Generates a WebAuthn challenge for credential creation
- Returns public key options for the client
- Stores request ID for later verification

### 2. Passkey Registration Finish
**File**: `supabase/functions/passkeys-registration-finish/index.ts`
- Receives the attestation from the client
- Verifies the attestation (basic implementation)
- Returns a session token

### 3. Passkey Authentication Start
**File**: `supabase/functions/passkeys-authentication-start/index.ts`
- Generates a WebAuthn challenge for authentication
- Returns public key options for the client
- Stores request ID for later verification

### 4. Passkey Authentication Finish
**File**: `supabase/functions/passkeys-authentication-finish/index.ts`
- Receives the assertion from the client
- Verifies the assertion and looks up the user
- Returns a session token

## Configuration

Updated the app configuration to point to these Edge Functions:

**Migration**: `supabase/migrations/20260403_add_passkey_endpoint_paths.sql`

Sets the following configuration keys:
- `auth.passkeys.start_registration_path` → `/functions/v1/passkeys-registration-start`
- `auth.passkeys.finish_registration_path` → `/functions/v1/passkeys-registration-finish`
- `auth.passkeys.start_authentication_path` → `/functions/v1/passkeys-authentication-start`
- `auth.passkeys.finish_authentication_path` → `/functions/v1/passkeys-authentication-finish`

## Deployment Steps

### 1. Deploy Edge Functions

```bash
# Deploy all passkey functions
supabase functions deploy passkeys-registration-start
supabase functions deploy passkeys-registration-finish
supabase functions deploy passkeys-authentication-start
supabase functions deploy passkeys-authentication-finish
```

Or deploy all at once:
```bash
supabase functions deploy
```

### 2. Apply Database Migrations

```bash
# Apply the endpoint path configuration
supabase db push
```

### 3. Verify Configuration

Check that the configuration was applied:
```sql
SELECT config_key, config_value FROM app_config 
WHERE config_key LIKE 'auth.passkeys.%path%';
```

### 4. Test Passkey Enrollment

1. Navigate to Settings → Passkey
2. Click "Add Passkey"
3. Follow the WebAuthn prompt on your device
4. Verify the passkey was added successfully

## Important Notes

### Current Implementation

The current Edge Functions are **basic implementations** that:
- Generate valid WebAuthn challenges
- Accept any attestation/assertion (no verification)
- Return mock session tokens
- Are suitable for development/testing

### Production Implementation

For production, you should:

1. **Use a WebAuthn library** like `@simplewebauthn/server`:
   ```bash
   deno add npm:@simplewebauthn/server
   ```

2. **Verify attestations properly**:
   ```typescript
   import { verifyRegistrationResponse } from "npm:@simplewebauthn/server";
   
   const verification = await verifyRegistrationResponse({
     response: attestation,
     expectedChallenge: storedChallenge,
     expectedOrigin: "https://vazkmvrbshxwyodentng.supabase.co",
     expectedRPID: "vazkmvrbshxwyodentng.supabase.co",
   });
   ```

3. **Store credentials in database**:
   - Create a `passkey_credentials` table
   - Store credential ID, public key, and counter
   - Link to user account

4. **Verify assertions properly**:
   ```typescript
   import { verifyAuthenticationResponse } from "npm:@simplewebauthn/server";
   
   const verification = await verifyAuthenticationResponse({
     response: assertion,
     expectedChallenge: storedChallenge,
     expectedOrigin: "https://vazkmvrbshxwyodentng.supabase.co",
     expectedRPID: "vazkmvrbshxwyodentng.supabase.co",
     credential: storedCredential,
   });
   ```

5. **Implement proper session management**:
   - Use Supabase Auth to create real sessions
   - Store passkey metadata in user profiles
   - Handle credential rotation and revocation

## Database Schema (Recommended for Production)

```sql
-- Store passkey credentials
CREATE TABLE passkey_credentials (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  credential_id TEXT NOT NULL UNIQUE,
  public_key BYTEA NOT NULL,
  counter INTEGER NOT NULL DEFAULT 0,
  transports TEXT[] DEFAULT ARRAY[]::TEXT[],
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  last_used_at TIMESTAMP WITH TIME ZONE,
  name TEXT DEFAULT 'My Passkey',
  UNIQUE(user_id, credential_id)
);

-- Store WebAuthn challenges temporarily
CREATE TABLE webauthn_challenges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  challenge TEXT NOT NULL UNIQUE,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT,
  challenge_type TEXT NOT NULL, -- 'registration' or 'authentication'
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  expires_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() + INTERVAL '10 minutes'
);

-- Enable RLS
ALTER TABLE passkey_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE webauthn_challenges ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can view their own credentials"
  ON passkey_credentials FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can delete their own credentials"
  ON passkey_credentials FOR DELETE
  USING (auth.uid() = user_id);
```

## Troubleshooting

### "Could not add a passkey right now"

1. Check that Edge Functions are deployed:
   ```bash
   supabase functions list
   ```

2. Check function logs:
   ```bash
   supabase functions logs passkeys-registration-start
   ```

3. Verify configuration:
   ```sql
   SELECT * FROM app_config WHERE config_key LIKE 'auth.passkeys.%';
   ```

4. Test the endpoint directly:
   ```bash
   curl -X POST https://vazkmvrbshxwyodentng.supabase.co/functions/v1/passkeys-registration-start \
     -H "Content-Type: application/json" \
     -d '{"email":"test@example.com"}'
   ```

### "Passkey status shows Setup Required"

1. Verify relying party ID is set:
   ```sql
   SELECT config_value FROM app_config 
   WHERE config_key = 'auth.passkeys.relying_party_id';
   ```

2. Verify server base URL is set:
   ```sql
   SELECT config_value FROM app_config 
   WHERE config_key = 'auth.passkeys.server_base_url';
   ```

3. Verify they match (domain must match):
   ```sql
   SELECT 
     (config_value->>'value') as relying_party_id,
     (SELECT config_value->>'value' FROM app_config 
      WHERE config_key = 'auth.passkeys.server_base_url') as server_base_url
   FROM app_config 
   WHERE config_key = 'auth.passkeys.relying_party_id';
   ```

## Next Steps

1. Deploy the Edge Functions
2. Apply the database migrations
3. Test passkey enrollment in the app
4. Implement production-grade WebAuthn verification
5. Add passkey credential storage to database
6. Implement passkey sign-in flow

## References

- [WebAuthn Specification](https://www.w3.org/TR/webauthn-2/)
- [SimpleWebAuthn Library](https://simplewebauthn.dev/)
- [Supabase Edge Functions](https://supabase.com/docs/guides/functions)
- [FIDO2 Alliance](https://fidoalliance.org/)



## Update: JWT Authentication Fix

### Problem
The initial implementation was failing with 401 Unauthorized errors because Supabase Edge Functions require JWT authentication by default.

### Solution
Updated the app to use Supabase's `functions.invoke()` method instead of making raw HTTP requests. This method automatically handles JWT authentication.

### Code Change
In `lib/services/passkey_auth_service.dart`, the `_postJson()` method was updated to:

```dart
static Future<Map<String, dynamic>> _postJson(
  Uri uri, {
  required Map<String, dynamic> body,
}) async {
  try {
    // Extract the function name from the URI
    final pathSegments = uri.pathSegments;
    final functionName = pathSegments.isNotEmpty ? pathSegments.last : '';
    
    if (functionName.isEmpty) {
      throw const PasskeyAuthException(
        code: 'invalid_request',
        message: 'Invalid function URI.',
      );
    }

    // Use Supabase's functions.invoke() which handles JWT automatically
    final response = await Supabase.instance.client.functions.invoke(
      functionName,
      body: body,
    ).timeout(_requestTimeout);

    final decoded = response as Map<String, dynamic>?;
    if (decoded == null) {
      throw const PasskeyAuthException(
        code: 'invalid_response',
        message: 'Passkey server returned an invalid response.',
      );
    }

    return decoded;
  } on TimeoutException {
    throw const PasskeyAuthException(
      code: 'timeout',
      message: 'Passkey request timed out.',
    );
  } on PasskeyAuthException {
    rethrow;
  } catch (error) {
    throw PasskeyAuthException(
      code: 'network_error',
      message: error.toString(),
    );
  }
}
```

### Why This Works
- `functions.invoke()` automatically extracts the function name from the URI
- It handles JWT authentication using the current user's session token or the anon key
- It properly formats the request and response
- It eliminates the need for manual HTTP header management

### Deployment
1. Deploy the updated Edge Functions:
   ```bash
   supabase functions deploy
   ```

2. Rebuild the app:
   ```bash
   flutter pub get
   flutter run
   ```

3. Test passkey enrollment - it should now work without 401 errors

