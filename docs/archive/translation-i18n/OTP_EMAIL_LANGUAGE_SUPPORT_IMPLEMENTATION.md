# OTP Email Language Support Implementation

## Overview
This document describes the implementation of language support for OTP confirmation emails. The user's selected UI language is now passed to Supabase Auth during signup, making it available in email templates via the `{{ .Data.language }}` variable.

## Implementation Summary

### ✅ Completed Changes

#### 1. **Client-Side (Flutter)**
**File:** `lib/screens/auth/auth_screen.dart`
- Modified `_performAuth()` method to pass the current UI language to signup
- Language is extracted from `l10n.currentLocale.languageCode`
- Supported languages: `'en'` (English), `'es'` (Spanish), `'he'` (Hebrew)

**File:** `lib/services/secure_signup_service.dart`
- Added optional `language` parameter to the `signUp()` method signature
- Language is included in the request body sent to the edge function (if provided)

#### 2. **Backend (Edge Function)**
**File:** `supabase/functions/secure-sign-up/index.ts`
- Added `language` field to the request body type definition
- Extracts language from the request body with `const language = normalizeText(body.language).toLowerCase()`
- Modified the Supabase Auth `/auth/v1/signup` API call to include language metadata:
  ```typescript
  body: JSON.stringify({
    email,
    password,
    ...(language && { options: { data: { language } } }),
  })
  ```

### Data Flow

```
1. User selects language on Auth Screen
   ↓
2. User clicks "Sign Up"
   ↓
3. _performAuth() extracts language: l10n.currentLocale.languageCode
   ↓
4. SecureSignupService.signUp() receives language parameter
   ↓
5. Request body includes: { email, password, captchaToken, language, fingerprint }
   ↓
6. Edge function extracts language and passes to Supabase Auth
   ↓
7. Supabase stores in auth.raw_user_meta_data: { "language": "en"|"es"|"he" }
   ↓
8. Email templates can use {{ .Data.language }} for localization
```

## Supabase Configuration (Next Steps)

### Email Template Setup
Supabase stores the language in auth metadata, but Supabase Email templates have **limited built-in localization support**. You have two options:

#### Option 1: Language-Specific Email Templates (Recommended)
**Current Limitation:** Supabase doesn't natively support conditional templates based on user metadata.
**Workaround:** Use a custom webhook-based solution:

1. Create a database table to store email templates by language:
   ```sql
   CREATE TABLE email_templates (
     id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
     template_type TEXT NOT NULL,
     language_code TEXT NOT NULL,
     subject TEXT NOT NULL,
     html_content TEXT NOT NULL,
     created_at TIMESTAMP DEFAULT now(),
     UNIQUE(template_type, language_code)
   );
   ```

2. Create a webhook trigger that intercepts auth events and sends custom html emails:
   - Trigger: User creation (after signup)
   - Fetch user's language from `auth.raw_user_meta_data`
   - Fetch corresponding email template
   - Send via Resend/SendGrid/your email provider

#### Option 2: Manual Template Update in Supabase Dashboard
1. Go to Supabase Dashboard → Authentication → Email Templates
2. Update the default "Confirm Email" template to include conditional content based on `{{ .Data.language }}`
   - **Note:** This requires Supabase template syntax support for conditionals
   - Current Supabase version may have limited support

### Manual Steps to Verify Implementation

1. **Check Edge Function Logs:**
   - Deploy the updated `secure-sign-up` function:
     ```bash
     supabase functions deploy secure-sign-up
     ```
   - Monitor logs during signup to verify language is received and passed

2. **Verify User Metadata:**
   - After a user signs up, check Supabase Auth Dashboard
   - Go to Users → Select user → View raw metadata
   - Should show: `{ "language": "en" }` (or "es", "he")

3. **Test Email Template Variable:**
   - Check if `{{ .Data.language }}` is available in your email templates
   - Templates are in Supabase Dashboard → Authentication → Email Templates

## Testing Checklist

- [ ] Deploy edge function: `supabase functions deploy secure-sign-up`
- [ ] Test signup with English (en) language selected
- [ ] Test signup with Spanish (es) language selected
- [ ] Test signup with Hebrew (he) language selected
- [ ] Verify user metadata contains language field in Supabase dashboard
- [ ] Check edge function logs for language being passed
- [ ] Configure email templates to use `{{ .Data.language }}` variable
- [ ] Send test email and verify language-specific content

## Files Changed

1. `lib/screens/auth/auth_screen.dart` - Pass language to signup
2. `lib/services/secure_signup_service.dart` - Accept language parameter
3. `supabase/functions/secure-sign-up/index.ts` - Extract and pass language metadata

## Support for Future Languages

To add support for additional languages:

1. Add language code to database (`app_languages` table)
2. No code changes needed - system will automatically support it
3. Update `translation_cache_manager.dart` hardcoded fallback if needed (currently: en, es, he)

## Notes

- Language codes follow IETF BCP 47 standard (ISO 639-1): 'en', 'es', 'he'
- If no language is provided, Supabase will use its default configuration
- The language is stored as **user metadata**, not in user attributes (persistent across sessions)
- Compatible with all Supabase Auth providers (email/password, OAuth, etc.)

## References

- [Supabase Auth Metadata Documentation](https://supabase.com/docs/guides/auth/managing-user-data)
- [Supabase Email Templates Documentation](https://supabase.com/docs/guides/auth/overview#authorize)
- [Supabase Edge Functions](https://supabase.com/docs/guides/functions)
