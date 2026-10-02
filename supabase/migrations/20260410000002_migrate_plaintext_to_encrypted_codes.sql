BEGIN;

-- Migrate any remaining plaintext codes to encrypted format
-- This handles codes that were created before the encryption migration
UPDATE public.sensitive_action_email_codes
SET encrypted_code = pgp_sym_encrypt(code, 'MATCHME_INTERNAL_SECRET')
WHERE encrypted_code IS NULL AND code IS NOT NULL;

COMMIT;
