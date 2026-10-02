-- Recreate is_admin_user function with better error handling
CREATE OR REPLACE FUNCTION public.is_admin_user(user_id uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  -- If user_id is provided, use it; otherwise try auth.uid()
  IF user_id IS NOT NULL THEN
    v_user_id := user_id;
  ELSE
    v_user_id := auth.uid();
  END IF;
  
  -- If still null, return false
  IF v_user_id IS NULL THEN
    RETURN false;
  END IF;
  
  RETURN EXISTS (
    SELECT 1 FROM public.users
    WHERE id = v_user_id AND is_admin = true
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_admin_user TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_admin_user TO anon;

-- Test with explicit user ID
SELECT public.is_admin_user('ffc20046-a777-463b-922a-547151aa1455') as is_admin_check;