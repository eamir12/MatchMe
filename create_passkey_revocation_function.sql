-- Create or update the revoke_all_passkeys RPC function for passkey management
-- This function allows users to revoke all their passkeys at once

CREATE OR REPLACE FUNCTION revoke_all_passkeys(p_user_id UUID)
RETURNS VOID AS $$
BEGIN
  -- Verify user is authenticated and removing their own passkeys
  IF auth.uid() != p_user_id THEN
    RAISE EXCEPTION 'Not authorized to revoke passkeys for other users';
  END IF;

  -- Delete all passkey credentials for this user
  -- NOTE: Using passkey_credentials table (not webauthn_credentials)
  DELETE FROM public.passkey_credentials 
  WHERE user_id = p_user_id;

  -- Log the revocation event if audit_log table exists
  BEGIN
    INSERT INTO public.audit_log (user_id, action, timestamp)
    VALUES (p_user_id, 'passkey_revocation', NOW());
  EXCEPTION WHEN OTHERS THEN
    -- Fail silently if audit_log doesn't exist or insert fails
    NULL;
  END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION revoke_all_passkeys(UUID) TO authenticated;
