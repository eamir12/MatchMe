CREATE OR REPLACE FUNCTION public.is_user_truly_visible(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
SELECT COALESCE((
  SELECT
    (
      EXISTS (
        SELECT 1
        FROM public.user_activity ua
        WHERE ua.user_id = p_user_id
          AND ua.is_online = TRUE
          AND ua.last_activity > NOW() - INTERVAL '30 seconds'
      )
      AND COALESCE(u.user_visibility_setting, false) = TRUE
      AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
    )
  FROM public.users u
  WHERE u.id = p_user_id
), FALSE);
$$;

GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO anon;
