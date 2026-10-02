BEGIN;

-- Drop the existing function to change its return type
DROP FUNCTION IF EXISTS public.get_active_sensitive_action_email_code(uuid, text);

-- Function to get the active email code for resending (without generating a new one)
-- Now includes created_at timestamp to check code age
CREATE OR REPLACE FUNCTION public.get_active_sensitive_action_email_code(
  p_user_id uuid,
  p_email text
)
RETURNS TABLE (
  code text,
  created_at timestamp with time zone,
  expires_at timestamp with time zone
) AS $$
BEGIN
  -- Find the most recent unused code for this user and email that hasn't expired
  RETURN QUERY
  SELECT 
    sensitive_action_email_codes.code,
    sensitive_action_email_codes.created_at,
    sensitive_action_email_codes.expires_at
  FROM public.sensitive_action_email_codes
  WHERE sensitive_action_email_codes.user_id = p_user_id 
    AND sensitive_action_email_codes.email = LOWER(p_email)
    AND sensitive_action_email_codes.used_at IS NULL
    AND sensitive_action_email_codes.expires_at > now()
  ORDER BY sensitive_action_email_codes.created_at DESC
  LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;
