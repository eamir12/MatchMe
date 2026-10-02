-- Migration: Fix set_user_offline function to update user_activity instead of users
-- Date: 2026-05-06
-- Purpose: Fix "column is_online of relation users does not exist" error on logout

-- Drop and recreate set_user_offline with correct table
DROP FUNCTION IF EXISTS public.set_user_offline(uuid);

CREATE OR REPLACE FUNCTION public.set_user_offline(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
BEGIN
  -- Update user_activity table (not users table)
  UPDATE user_activity
  SET is_online = false,
      updated_at = NOW()
  WHERE user_id = p_user_id;

  -- Insert if no record exists
  INSERT INTO user_activity (
    user_id,
    last_activity,
    is_online,
    is_visible,
    updated_at
  )
  SELECT
    p_user_id,
    NOW(),
    false,
    COALESCE((SELECT user_visibility_setting FROM users WHERE id = p_user_id), false),
    NOW()
  WHERE NOT EXISTS (SELECT 1 FROM user_activity WHERE user_id = p_user_id);
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid) TO anon;

COMMENT ON FUNCTION public.set_user_offline IS
  'Marks a user as offline in the user_activity table. Updates existing record or creates new one if needed.';

COMMIT;