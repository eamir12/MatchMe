BEGIN;

-- Drop the plaintext code column entirely - only encrypted_code is needed
ALTER TABLE public.sensitive_action_email_codes
DROP COLUMN IF EXISTS code;

COMMIT;
