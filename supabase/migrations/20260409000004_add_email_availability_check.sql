BEGIN;

-- Function to check if an email is available (not in use by another user)
CREATE OR REPLACE FUNCTION public.check_email_availability(
  p_email text,
  p_exclude_user_id uuid DEFAULT NULL
)
RETURNS TABLE (
  available boolean,
  message text
) AS $$
DECLARE
  v_existing_user_id uuid;
BEGIN
  -- Check if email exists in auth.users
  SELECT id INTO v_existing_user_id
  FROM auth.users
  WHERE email = LOWER(p_email)
    AND (p_exclude_user_id IS NULL OR id != p_exclude_user_id)
  LIMIT 1;
  
  IF v_existing_user_id IS NOT NULL THEN
    RETURN QUERY SELECT false, 'This email address is already in use'::text;
  ELSE
    RETURN QUERY SELECT true, 'Email is available'::text;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;
