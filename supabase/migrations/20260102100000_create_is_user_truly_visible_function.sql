-- Create helper to compute true visibility: online + user setting + system status
CREATE OR REPLACE FUNCTION public.is_user_truly_visible(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
AS $$
-- Return TRUE only if user exists and satisfies (online + user setting + system visible)
-- Default to FALSE when user is missing to make calling code simpler and deterministic
SELECT COALESCE((
  SELECT
    (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = p_user_id AND ua.is_online = TRUE)
     AND COALESCE(u.user_visibility_setting, false) = TRUE
     AND COALESCE(u.system_visibility_status, 'visible') = 'visible')
  FROM users u
  WHERE u.id = p_user_id
), FALSE);
$$;

GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO anon;
