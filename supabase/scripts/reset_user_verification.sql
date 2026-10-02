-- Reset user verification status bypassing the protected fields trigger
-- Use this to manually reset a user's verification status

BEGIN;

-- Bypass protection by setting session variable
SET LOCAL app.bypass_protected_fields = true;

-- Reset verification status for user
UPDATE public.users
SET 
  is_verified = false,
  verification_status = 'unverified',
  verification_photo_path = NULL,
  verification_submitted_at = NULL,
  verification_reviewed_at = NULL
WHERE id = 'USER_ID_HERE';

COMMIT;