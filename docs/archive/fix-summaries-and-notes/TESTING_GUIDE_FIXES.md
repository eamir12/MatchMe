# Security Sign-In Screen - Testing Guide for Fixes

## Quick Start

1. **Rebuild the app:**
   ```bash
   flutter clean
   flutter pub get
   flutter run
   ```

2. **Navigate to:** Settings → Security & Sign-In

3. **Test each fix** using the checklist below

---

## Test 1: Passkey Status Display

### Scenario A: No Passkeys Registered
**Steps:**
1. Go to Settings → Security & Sign-In
2. Look at Passkeys section

**Expected Results:**
- ✅ Status badge shows "Disabled" (not "Enabled")
- ✅ Status color is gray (not green)
- ✅ Add Passkey button is enabled
- ✅ Remove Passkey button is disabled (grayed out)

**If Failed:**
- Check that `_checkHasRegisteredPasskeys()` is being called
- Verify `PasskeyAuthService.startAuthentication()` returns no credentials
- Check debug logs for passkey check results

---

### Scenario B: Passkey Registered
**Steps:**
1. Add a passkey (if not already done)
2. Go to Settings → Security & Sign-In
3. Look at Passkeys section

**Expected Results:**
- ✅ Status badge shows "Enabled" (green)
- ✅ Status color is green
- ✅ Add Passkey button is enabled
- ✅ Remove Passkey button is enabled

**If Failed:**
- Check that passkey was successfully registered
- Verify `_checkHasRegisteredPasskeys()` detects the passkey
- Check debug logs: `[SecuritySignIn] Passkey check result: true`

---

## Test 2: Remove Passkey Button Availability

### Scenario A: Button Should Be Disabled
**Steps:**
1. Ensure no passkeys are registered
2. Go to Settings → Security & Sign-In
3. Look at Remove Passkey button

**Expected Results:**
- ✅ Button appears grayed out (disabled)
- ✅ Clicking button does nothing
- ✅ Cursor shows "not-allowed" icon

**If Failed:**
- Check that `hasPasskeys` is false
- Verify button's `onPressed` condition: `(hasPasskeys && !_isEnrollingPasskey)`

---

### Scenario B: Button Should Be Enabled
**Steps:**
1. Register a passkey
2. Go to Settings → Security & Sign-In
3. Look at Remove Passkey button

**Expected Results:**
- ✅ Button appears normal (enabled)
- ✅ Clicking button opens confirmation dialog
- ✅ Cursor shows normal pointer

**If Failed:**
- Check that passkey is registered
- Verify `_checkHasRegisteredPasskeys()` returns true
- Check button's `onPressed` is not null

---

## Test 3: Update 2FA Button Error

### Scenario A: First-Time MFA Setup
**Steps:**
1. Ensure MFA is not enabled
2. Go to Settings → Security & Sign-In
3. Click "Enable 2FA" button

**Expected Results:**
- ✅ MFA enrollment dialog opens
- ✅ Loading spinner shows briefly
- ✅ QR code displays
- ✅ Secret key shows
- ✅ No "Something went wrong" error

**If Failed:**
- Check debug logs for enrollment error: `[MFA] Enrollment error:`
- Verify Supabase MFA is configured
- Check that user doesn't already have MFA enabled

---

### Scenario B: Update Existing MFA
**Steps:**
1. Ensure MFA is already enabled
2. Go to Settings → Security & Sign-In
3. Click "Update 2FA" button

**Expected Results:**
- ✅ MFA enrollment dialog opens
- ✅ Loading spinner shows briefly
- ✅ QR code displays (new secret)
- ✅ Secret key shows (new secret)
- ✅ No "Something went wrong" error

**If Failed:**
- Check debug logs for enrollment error
- Verify existing MFA factor can be unenrolled
- Check Supabase MFA configuration

---

### Scenario C: MFA Verification
**Steps:**
1. In MFA enrollment dialog, enter 6-digit code from authenticator
2. Click "Verify" button

**Expected Results:**
- ✅ Loading spinner shows
- ✅ Code is verified
- ✅ Dialog closes
- ✅ Success message shows: "Two-factor authentication enabled successfully"

**If Failed:**
- Check that code is correct (6 digits)
- Verify authenticator app is synced
- Check Supabase MFA verification

---

## Test 4: Email Code Verification for MFA

### Scenario A: Email Code Option Available
**Steps:**
1. Go to Settings → Security & Sign-In
2. Click "Update 2FA" button
3. Complete QR code verification
4. Look for email code option

**Expected Results:**
- ✅ Email code option is available
- ✅ Can switch between authenticator and email code
- ✅ Email code button shows "Use Email Code"

**If Failed:**
- Check that email code is enabled in settings_screen.dart
- Verify user has email address
- Check MFA verification dialog implementation

---

### Scenario B: Send Email Code
**Steps:**
1. In MFA verification dialog, click "Use Email Code"
2. Click "Send Email Code" button

**Expected Results:**
- ✅ Code is sent to email
- ✅ Success message shows
- ✅ Resend button shows with cooldown timer
- ✅ Email received with 6-digit code

**If Failed:**
- Check email configuration in Supabase
- Verify user email is correct
- Check email sending logs

---

### Scenario C: Verify Email Code
**Steps:**
1. Receive email code
2. Enter 6-digit code in dialog
3. Click "Verify" button

**Expected Results:**
- ✅ Code is verified
- ✅ Dialog closes
- ✅ Success message shows

**If Failed:**
- Check that code is correct
- Verify code hasn't expired
- Check Supabase email code verification

---

## Test 5: Passkey Authentication for Sensitive Actions

### Scenario A: Change Password with Passkey
**Steps:**
1. Register a passkey
2. Go to Settings → Security & Sign-In
3. Click "Change Password" button

**Expected Results:**
- ✅ Passkey authentication dialog appears
- ✅ User can authenticate with passkey
- ✅ After successful auth, password change dialog opens
- ✅ Can change password

**Debug Logs:**
```
[SecuritySignIn] Starting passkey authentication for sensitive action
[SecuritySignIn] Got challenge, getting assertion
[SecuritySignIn] Finishing authentication
[SecuritySignIn] Passkey authentication successful
```

**If Failed:**
- Check debug logs for passkey auth errors
- Verify passkey is registered
- Check that passkey authentication works

---

### Scenario B: Add Passkey with Existing Passkey
**Steps:**
1. Register a passkey
2. Go to Settings → Security & Sign-In
3. Click "Add Passkey" button

**Expected Results:**
- ✅ Passkey authentication dialog appears
- ✅ User authenticates with existing passkey
- ✅ After auth, new passkey enrollment starts
- ✅ Can add second passkey

**If Failed:**
- Check that existing passkey is detected
- Verify passkey authentication works
- Check passkey enrollment process

---

### Scenario C: Remove Passkey with Passkey Auth
**Steps:**
1. Register a passkey
2. Go to Settings → Security & Sign-In
3. Click "Remove Passkey" button

**Expected Results:**
- ✅ Passkey authentication dialog appears
- ✅ User authenticates with passkey
- ✅ After auth, confirmation dialog appears
- ✅ Can confirm removal

**If Failed:**
- Check that passkey auth is triggered
- Verify passkey authentication works
- Check passkey removal process

---

### Scenario D: Fallback to MFA
**Steps:**
1. Register MFA but no passkey
2. Go to Settings → Security & Sign-In
3. Click "Change Password" button

**Expected Results:**
- ✅ MFA challenge dialog appears (not passkey)
- ✅ User enters 6-digit code
- ✅ After MFA verification, password change dialog opens

**If Failed:**
- Check that passkey check returns false
- Verify MFA is enabled
- Check MFA challenge dialog

---

### Scenario E: Deny Action (No Auth Method)
**Steps:**
1. Ensure no passkey and no MFA
2. Go to Settings → Security & Sign-In
3. Click "Change Password" button

**Expected Results:**
- ✅ Error message shows: "2-Factor authentication is not enabled"
- ✅ Password change dialog does NOT open
- ✅ Action is denied

**If Failed:**
- Check that both passkey and MFA checks return false
- Verify error message is shown
- Check that action is properly denied

---

## Debug Logging

### Enable Debug Logs
All fixes include debug logging. Check console output for:

```
[SecuritySignIn] Starting passkey authentication for sensitive action
[SecuritySignIn] Got challenge, getting assertion
[SecuritySignIn] Finishing authentication
[SecuritySignIn] Passkey authentication successful
[SecuritySignIn] Passkey client error: ...
[SecuritySignIn] Passkey auth error: ...
[SecuritySignIn] Passkey authentication error: ...
[MFA] Enrollment error: ...
```

### Check Passkey Status
Look for:
```
[SecuritySignIn] Passkey check result: true/false
[SecuritySignIn] No passkey credentials available
```

---

## Common Issues & Solutions

### Issue: "Passkey shows Enabled but I didn't register one"
**Solution:**
- Check that `_checkHasRegisteredPasskeys()` is being called
- Verify `PasskeyAuthService.startAuthentication()` is working
- Check debug logs for passkey check results

### Issue: "Remove button is still enabled when no passkeys"
**Solution:**
- Verify `hasPasskeys` variable is being updated
- Check that `_refreshPasskeyState()` is called after passkey operations
- Ensure nested FutureBuilder is properly structured

### Issue: "Update 2FA still shows error"
**Solution:**
- Check debug logs for enrollment error details
- Verify Supabase MFA is configured
- Check that user doesn't have conflicting MFA setup
- Try unenrolling existing MFA first

### Issue: "Passkey auth not triggered for sensitive actions"
**Solution:**
- Verify passkey is registered
- Check that `_checkHasRegisteredPasskeys()` returns true
- Verify `_authenticateWithPasskeyForSensitiveAction()` is called
- Check debug logs for passkey auth flow

---

## Performance Notes

- Passkey check is cached in `_hasRegisteredPasskeysFuture`
- Passkey check is refreshed after passkey operations
- MFA status is cached with 8-second timeout
- All async operations have proper error handling

---

## Accessibility Testing

- [ ] All buttons have proper labels
- [ ] All dialogs have proper titles
- [ ] Error messages are clear
- [ ] Loading states are visible
- [ ] Disabled buttons show proper visual feedback
- [ ] Color is not the only indicator (icons used too)

---

## Security Testing

- [ ] Passkey auth required for sensitive actions
- [ ] MFA fallback works when passkey unavailable
- [ ] Actions denied when no auth method available
- [ ] Session is properly verified after auth
- [ ] No sensitive data logged

---

## Completion Checklist

- [ ] Test 1: Passkey Status Display - PASSED
- [ ] Test 2: Remove Passkey Button - PASSED
- [ ] Test 3: Update 2FA Button - PASSED
- [ ] Test 4: Email Code Verification - PASSED
- [ ] Test 5: Passkey Auth for Sensitive Actions - PASSED
- [ ] Debug Logging - VERIFIED
- [ ] Common Issues - RESOLVED
- [ ] Performance - ACCEPTABLE
- [ ] Accessibility - VERIFIED
- [ ] Security - VERIFIED

---

**All tests passed?** ✅ Ready for production!
