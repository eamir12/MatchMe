# Resend Email Code - 10 Minute Age Check Implementation

## Overview
Implemented logic to check if the last email code sent is older than 10 minutes. If it is, a new code is generated and sent. If it's still fresh (less than 10 minutes old), the existing code is resent.

## Changes Made

### 1. Database Migration Updated ✅
**File:** `supabase/migrations/20260409000000_add_resend_email_code_function.sql`

**Change:** Updated `get_active_sensitive_action_email_code()` function to return the `created_at` timestamp

```sql
RETURNS TABLE (
  code text,
  created_at timestamp with time zone,  -- ✅ NEW
  expires_at timestamp with time zone
)
```

**Why:** The backend needs to know when the code was created to calculate its age.

---

### 2. Backend Function Enhanced ✅
**File:** `supabase/functions/sensitive-action-email-code/index.ts`
**Function:** `handleResend()`

**Logic Flow:**

```
User clicks "Resend Code"
    ↓
Check if active code exists
    ↓
    ├─ NO CODE FOUND
    │  └─ Generate new code → Send email
    │
    └─ CODE FOUND
       ├─ Calculate code age: (now - created_at)
       │
       ├─ Age > 10 minutes?
       │  ├─ YES → Generate new code → Send email
       │  └─ NO → Resend existing code
```

**Implementation Details:**

```typescript
// Check if the existing code is older than 10 minutes
const codeCreatedAt = new Date(data[0].created_at);
const now = new Date();
const ageInMinutes = (now.getTime() - codeCreatedAt.getTime()) / (1000 * 60);

if (ageInMinutes > 10) {
  // Code is older than 10 minutes, generate a new one
  console.log(`Existing code is ${ageInMinutes.toFixed(2)} minutes old, generating new code`);
  // Generate new code...
} else {
  // Code is still fresh, use the existing one
  console.log(`Existing code is ${ageInMinutes.toFixed(2)} minutes old, reusing existing code`);
  // Resend existing code...
}
```

**Response Messages:**
- If new code generated: `"New email code generated and sent"`
- If existing code resent: `"Email code resent"`

---

## Behavior

### Scenario 1: First Resend (Code < 10 minutes old)
```
User requests code at 10:00 AM
User clicks "Resend" at 10:05 AM (5 minutes later)
→ System checks: Code is 5 minutes old
→ System resends the SAME code
→ Message: "Email code resent"
```

### Scenario 2: Late Resend (Code > 10 minutes old)
```
User requests code at 10:00 AM
User clicks "Resend" at 10:15 AM (15 minutes later)
→ System checks: Code is 15 minutes old
→ System generates a NEW code
→ System sends the NEW code
→ Message: "New email code generated and sent"
```

### Scenario 3: No Active Code
```
User requests code at 10:00 AM
Code expires at 10:10 AM
User clicks "Resend" at 10:15 AM (after expiration)
→ System checks: No active code found
→ System generates a NEW code
→ System sends the NEW code
→ Message: "New email code generated and sent"
```

---

## Code Age Calculation

The age is calculated in minutes:
```typescript
const ageInMinutes = (now.getTime() - codeCreatedAt.getTime()) / (1000 * 60);
```

**Examples:**
- Code created at 10:00:00, checked at 10:05:30 → Age = 5.5 minutes → Resend existing
- Code created at 10:00:00, checked at 10:10:01 → Age = 10.016 minutes → Generate new
- Code created at 10:00:00, checked at 10:15:00 → Age = 15 minutes → Generate new

---

## Logging

The system logs code age checks for debugging:

```
// When code is fresh
"Existing code is 5.50 minutes old, reusing existing code"

// When code is old
"Existing code is 15.00 minutes old, generating new code"

// When no code exists
"No active code found, generating new code"
```

---

## Database Schema

The `sensitive_action_email_codes` table already has the required fields:

```sql
CREATE TABLE public.sensitive_action_email_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL,
  code text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),  -- ✅ Used for age check
  expires_at timestamp with time zone NOT NULL,
  used_at timestamp with time zone,
  ...
);
```

---

## Security Considerations

1. **Code Expiration:** Codes still expire after 10 minutes regardless of resends
2. **One-Time Use:** Codes can only be used once (marked with `used_at`)
3. **User Verification:** Email must match authenticated user's email
4. **Rate Limiting:** Handled by Supabase auth exceptions
5. **Timestamp Precision:** Uses server-side timestamps (PostgreSQL `now()`)

---

## Testing Checklist

- [ ] Test resending code within 10 minutes (should resend same code)
- [ ] Test resending code after 10 minutes (should generate new code)
- [ ] Test resending code after expiration (should generate new code)
- [ ] Verify console logs show correct age calculations
- [ ] Verify response messages are correct
- [ ] Test with different timezones
- [ ] Verify old code cannot be used after new code is generated
- [ ] Test edge case: exactly 10 minutes (should generate new)
- [ ] Test edge case: 9:59 minutes (should resend existing)

---

## Files Modified

1. `supabase/migrations/20260409000000_add_resend_email_code_function.sql`
   - Updated `get_active_sensitive_action_email_code()` to return `created_at`

2. `supabase/functions/sensitive-action-email-code/index.ts`
   - Enhanced `handleResend()` with 10-minute age check logic
   - Added code age calculation
   - Added conditional code generation vs resend logic
   - Added detailed logging

---

## Summary

The resend email code feature now intelligently manages code lifecycle:
- **Fresh codes (< 10 min):** Resend the same code to avoid confusion
- **Old codes (≥ 10 min):** Generate a new code for security
- **Expired codes:** Generate a new code automatically

This provides a better user experience while maintaining security by ensuring codes don't stay valid indefinitely.
