# Email Code Validation Fix for Sensitive Actions

## Problem
The app was accepting any 6-digit code for sensitive actions (password change, deactivate authenticator, delete passkeys) instead of validating against the specific code sent via email. This was a critical security vulnerability.

## Root Cause
The original implementation relied on Supabase's `auth.updateUser(nonce: code)` to validate email codes. However, the `nonce` parameter is just metadata storage and does NOT perform validation. Supabase doesn't validate that the nonce matches any previously sent code.

## Solution
Implemented a proper backend validation system with:

### 1. Database Schema (`supabase/migrations/20260408000000_create_email_code_validation.sql`)
- **Table**: `sensitive_action_email_codes` - Stores generated email codes with:
  - `user_id`: User who requested the code
  - `email`: Email address the code was sent to
  - `code`: The 6-digit code
  - `created_at`: When the code was generated
  - `expires_at`: When the code expires (10 minutes)
  - `used_at`: When the code was used (NULL if unused)

- **RLS Policies**: Users can only view their own codes; service role can insert/update

- **Functions**:
  - `generate_sensitive_action_email_code()`: Generates a random 6-digit code and stores it
  - `verify_sensitive_action_email_code()`: Validates the code against stored value, checks expiration, and marks as used
  - `cleanup_expired_email_codes()`: Removes expired codes (can be called by cron job)

### 2. Edge Function (`supabase/functions/sensitive-action-email-code/index.ts`)
- **Endpoint**: `POST /functions/v1/sensitive-action-email-code`
- **Actions**:
  - `generate`: Creates a new email code, stores it in the database, and sends an email with the code
  - `verify`: Validates the provided code against the stored code
- **Email Sending**: Uses Supabase's `auth.admin.sendRawEmail()` to send a custom HTML email with the verification code
- **Security**: Validates that the authenticated user's email matches the email the code was sent to

### 3. Updated Service (`lib/services/sensitive_action_reauth_service.dart`)
- **`sendEmailCode()`**: Now calls the backend to generate, store, and send the code
- **`verifyEmailCode()`**: Now validates the code against the backend before accepting it
- **`_generateEmailCodeOnBackend()`**: New method to invoke the edge function for code generation and email sending
- **`_verifyEmailCodeWithBackend()`**: New method to invoke the edge function for code verification

## Email Flow
After deployment, here's what happens when a user initiates a sensitive action:

1. **User chooses "Email code" verification**: App calls `sendEmailCode()`
2. **Backend generates code**: Edge function generates a random 6-digit code
3. **Code is stored**: Code is saved in `sensitive_action_email_codes` table with 10-minute expiration
4. **Email is sent**: Edge function sends a custom HTML email with the code to the user
5. **User receives email**: Email contains the 6-digit code and security information
6. **User enters code**: App calls `verifyEmailCode()` with the code
7. **Backend validates**: Edge function checks if the code matches, hasn't expired, and hasn't been used
8. **Code is marked used**: If valid, the code is marked as used in the database
9. **Action proceeds**: If validation succeeds, the sensitive action is allowed

## Security Improvements
1. **Server-side validation**: Codes are validated on the backend, not just the client
2. **Code expiration**: Codes expire after 10 minutes
3. **One-time use**: Codes can only be used once (marked as used after verification)
4. **Email verification**: Ensures the code was sent to the user's current email
5. **User isolation**: Users can only verify codes sent to their own account
6. **Audit trail**: All code generation and usage is logged in the database
7. **Custom email**: Email is sent with a branded template containing the code

## Implementation Steps

### 1. Deploy Database Migration
```bash
supabase migration up
```

### 2. Deploy Edge Function
The edge function is automatically deployed when you push to Supabase:
```bash
supabase functions deploy sensitive-action-email-code
```

### 3. Update App Code
The app code has been updated to use the new backend validation. No additional changes needed.

## Testing
To test the fix:

1. **Generate a code**: Initiate a sensitive action (e.g., change password)
2. **Request email code**: Choose "Email code" as verification method
3. **Verify email is sent**: Check that an email is received with a 6-digit code in a branded template
4. **Test invalid code**: Try entering a different 6-digit code - should fail with "Invalid email code"
5. **Test correct code**: Enter the code from the email - should succeed
6. **Test code reuse**: Try using the same code again - should fail with "Invalid email code" (already used)
7. **Test expiration**: Wait 10+ minutes and try using the code - should fail with "Email code has expired"

## Database Cleanup
To clean up expired codes, you can:

1. **Manual cleanup**: Call the function directly
   ```sql
   SELECT public.cleanup_expired_email_codes();
   ```

2. **Automated cleanup**: Set up a Supabase cron job to run periodically
   ```sql
   SELECT cron.schedule('cleanup-expired-email-codes', '0 * * * *', 'SELECT public.cleanup_expired_email_codes()');
   ```

## Backward Compatibility
- The changes are backward compatible
- Existing sessions continue to work
- Only new email code verification uses the new system

## Email Template
The email sent contains:
- Clear subject: "Your verification code for sensitive account changes"
- Branded header explaining the action
- Large, easy-to-read 6-digit code
- Expiration time (10 minutes)
- Security warning about not sharing the code
- Professional HTML formatting

## Future Enhancements
1. Add rate limiting to prevent brute force attacks
2. Add SMS codes as an alternative
3. Add metrics/monitoring for code generation and verification
4. Customize email template with app branding
5. Support for multiple languages in email template
