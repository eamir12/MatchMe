BEGIN;

-- Create a debug function to test encryption/decryption
CREATE OR REPLACE FUNCTION public.debug_decrypt_code(p_encrypted bytea)
RETURNS TABLE (
  decrypted_code text
) AS $$
BEGIN
  RETURN QUERY
  SELECT pgp_sym_decrypt(p_encrypted, 'MATCHME_INTERNAL_SECRET')::text;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;
