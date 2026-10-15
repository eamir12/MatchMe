# Email Change Feature Implementation

> **ARCHIVED / SUPERSEDED.** The dedicated `send-email-change-otp` and
> `verify-email-change-otp` edge functions described here were removed from the
> codebase (2026-10-15). They were never called by the app; the live email-change
> flow is handled by the `sensitive-action-email-code` edge function (actions:
> `generate_email_change_code`, `verify_email_change_code`,
> `complete_email_change`, `send_email_changed_notification`) plus the
> `generate_email_change_code` / `verify_email_change_code` /
> `complete_email_change` RPCs — see `lib/services/email_change_service.dart`.
> Additionally, `send-email-change-otp` called `auth.admin.sendEmail`, a
> non-existent Supabase API, so it could never have delivered email.

## Overview
This feature allows users to change their email address with a secure two-step verification process:
1. **MFA Verification** - User must verify their identity with MFA
2. **Email Confirmation** - User receives a verification code on their new email via Supabase's email service and must confirm it

## Files Created

### 1. Translation Keys
**File:** `supabase/migrations/20260409000002_add_email_change_translations.sql`

Adds 30+ translation keys in English, Spanish, and Hebrew for:
- Screen titles and descriptions
- Form labels and hints
- Step indicators
- Success/error messages
- Button labels

### 2. Email Change Service
**File:** `lib/services/email_change_service.dart`

Provides:
- `requestEmailChangeCode()` - Request verification code for new email
- `verifyEmailChangeCode()` - Verify the code from new email
- `completeEmailChange()` - Update email in Supabase Auth
- Error handling with `EmailChangeException`
- Code expiry tracking (15 minutes)

### 3. Email Change Screen
**File:** `lib/screens/settings/email_change_screen.dart`

Features:
- 3-step wizard UI (MFA → Email Input → Code Verification)
- Visual step indicator
- Real-time code expiry countdown
- Resend code functionality
- Error and success messages
- Automatic navigation on completion

### 4. Settings Screen Integration
**File:** `lib/screens/settings/settings_screen.dart`

Added:
- Change Email button next to Change Password button
- `_showChangeEmailDialog()` method that navigates to EmailChangeScreen after MFA verification
- Import for EmailChangeScreen

### 5. Edge Functions
**Files:**
- `supabase/functions/send-email-change-otp/index.ts` - Generates and sends OTP to new email
- `supabase/functions/verify-email-change-otp/index.ts` - Verifies the OTP code

## Flow

### User Journey
1. User navigates to email change screen
2. System checks if MFA is verified
   - If not: User completes MFA verification first
3. User enters new email address
4. System sends verification code to new email via Supabase email service
5. User enters code from email
6. System verifies code and updates email in Supabase Auth
7. Success message shown and user returns to settings

### Security Features
- **MFA Required** - Must verify identity before changing email
- **Email Confirmation** - New email must be confirmed via OTP
- **Code Expiry** - Codes expire after 15 minutes
- **Secure Storage** - OTP stored in user metadata with expiry
- **Validation** - Email format and uniqueness checks
- **Rate Limiting** - Supabase's built-in rate limiting applies

## Integration Steps

### 1. Run Migrations
```bash
supabase migration up
```

This will add the translation keys to your database.

### 2. Deploy Edge Functions
```bash
supabase functions deploy send-email-change-otp
supabase functions deploy verify-email-change-otp
```

### 3. Configure Email Template (Optional)
In your Supabase dashboard, you can customize the email template for `email_change` emails. The OTP code is passed as `{{ .token }}`.

## Translation Keys Reference

All keys follow the pattern `settingsChangeEmail*`:
- `settingsChangeEmailTitle`
- `settingsChangeEmailDescription`
- `settingsChangeEmailCurrentEmail`
- `settingsChangeEmailNewEmail`
- `settingsChangeEmailStep1Title`
- `settingsChangeEmailStep2Title`
- `settingsChangeEmailVerificationCode`
- `settingsChangeEmailSendCode`
- `settingsChangeEmailVerifyCode`
- `settingsChangeEmailSuccess`
- `settingsChangeEmailError`
- And more...

All keys are available in English (en), Spanish (es), and Hebrew (he).

## Error Handling

The service handles:
- Invalid email format
- Same email as current
- Expired codes
- Invalid codes
- Network timeouts
- Authentication failures
- Email sending failures

## Testing

To test the feature:
1. Create a test user account
2. Enable MFA on the account
3. Navigate to email change screen
4. Follow the 3-step process
5. Verify email is updated in Supabase Auth

## How It Works

The feature uses Supabase's email service with custom edge functions:

1. **Request Code**: When user enters new email, `send-email-change-otp` edge function:
   - Generates a 6-digit OTP code
   - Stores it in user metadata with 15-minute expiry
   - Sends email via Supabase's `admin.sendEmail()` using the `email_change` template

2. **Verify Code**: User enters the code, `verify-email-change-otp` edge function:
   - Retrieves the stored OTP from user metadata
   - Validates the code and expiry
   - Clears the OTP from metadata

3. **Update Email**: Once verified, `updateUser()` is called to update the authenticated user's email in Supabase Auth.

This approach:
- Uses Supabase's native email infrastructure
- Stores OTP securely in user metadata
- Automatically integrates with Supabase's rate limiting
- Works with any email provider configured in Supabase
- No external email service configuration needed
