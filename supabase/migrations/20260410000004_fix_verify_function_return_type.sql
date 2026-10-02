BEGIN;

-- Drop and recreate the verify function with correct return type
DROP FUNCTION IF EXISTS public.verify_sensitive_action_email_code(uuid, text, text);

CREATE OR REPLACE FUNCTION public.verify_sensitive_action_email_code(
  p_user_id uuid,
  p_email text,
  p_code text
)
RETURNS TABLE (
  success boolean,
  message text
) AS $$
DECLARE
  v_stored_code text;
  v_code_record record;
BEGIN
  -- Find the most recent unused code for this user and email that hasn't expired
  SELECT 
    pgp_sym_decrypt(encrypted_code, 'MATCHME_INTERNAL_SECRET')::text as decrypted_code,
    id,
    expires_at
  INTO v_code_record
  FROM public.sensitive_action_email_codes
  WHERE user_id = p_user_id 
    AND email = LOWER(p_email)
    AND used_at IS NULL
    AND expires_at > now()
  ORDER BY created_at DESC
  LIMIT 1;
  
  -- Check if code was found
  IF v_code_record IS NULL THEN
    RETURN QUERY SELECT false, 'No valid code found for this email';
    RETURN;
  END IF;
  
  -- Compare the provided code with the decrypted stored code
  IF v_code_record.decrypted_code = p_code THEN
    -- Mark the code as used
    UPDATE public.sensitive_action_email_codes
    SET used_at = now()
    WHERE id = v_code_record.id;
    
    RETURN QUERY SELECT true, 'Code verified successfully';
  ELSE
    RETURN QUERY SELECT false, 'Invalid code';
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;
