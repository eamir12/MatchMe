# Sensitive Action Email Codes: Encryption & Auto-Deletion Implementation

## Overview
Implemented end-to-end encryption for sensitive action email codes with automatic deletion after 15 minutes.

## Changes Made

### 1. Database Migration (`20260410000000_encrypt_sensitive_action_email_codes.sql`)

#### New Column
- Added `encrypted_code bytea` column to store encrypted codes using pgcrypto
- Removed `code` column entirely—only encrypted codes stored at rest

#### Encryption Strategy
- Uses PostgreSQL's `pgcrypto` extension with `pgp_sym_encrypt()` for AES encryption
- Encryption key sourced from `app.encryption_key` setting (stored in Supabase vault)
- Codes encrypted at rest in the database

#### Updated Functions

**`generate_sensitive_action_email_code()`**
- Generates 6-digit code as before
- Encrypts code before storing: `pgp_sym_encrypt(v_code, v_encryption_key)`
- Returns plaintext code to client for email sending
- Stores both plaintext (temporary) and encrypted versions

**`verify_sensitive_action_email_code()`**
- Decrypts stored code: `pgp_sym_decrypt(encrypted_code, v_encryption_key)`
- Compares decrypted code with provided code
- Marks code as used upon successful verification

**`get_active_sensitive_action_email_code()`**
- Decrypts code before returning to client
- Used for resending codes without generating new ones

**`cleanup_expired_email_codes()`** (NEW)
- Deletes codes created more than 15 minutes ago
- Accepts optional `p_limit` parameter (default: 1000)
- Returns count of deleted rows

### 2. Cron Job Integration (`supabase/functions/cron-jobs/index.ts`)

#### New Handler Function
```typescript
async function handleCleanupExpiredEmailCodes(invocationId: string)
```
- Calls `cleanup_expired_email_codes()` RPC with limit of 1000
- Logs deletion count and execution details
- Follows existing error handling pattern

#### Task Execution
- Added to cron task list, runs after notification queue processing
- Executes on the same schedule as other cleanup tasks

## Security Benefits

1. **Encryption at Rest**: Codes encrypted in database, not visible to unauthorized database access
2. **Automatic Expiration**: Codes deleted after 15 minutes, reducing exposure window
3. **Decryption on Demand**: Codes only decrypted during verification
4. **Audit Trail**: All cron executions logged via existing `logEdgeFunctionInvocation()`

## Configuration

Uses `MATCHME_INTERNAL_SECRET` from Supabase vault for encryption. No additional configuration needed—the secret is already available in your Supabase project.

## Backward Compatibility

- Existing plaintext codes migrated to encrypted format during first migration
- `code` column dropped in second migration
- All functions updated to use encrypted codes only
- No breaking changes to API

## Cleanup Schedule

- Runs as part of cron job (typically every 5-10 minutes depending on Supabase schedule)
- Deletes codes older than 15 minutes
- Processes up to 1000 codes per execution
- Logs deletion count for monitoring

## Testing Recommendations

1. Generate a code and verify it encrypts properly
2. Verify code can be decrypted and validated correctly
3. Test cleanup function deletes codes after 15 minutes
4. Monitor cron job logs for cleanup task execution
5. Verify no codes remain after 15 minutes
