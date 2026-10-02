-- Align all online count functions to use 61 seconds threshold
-- 61 seconds = 2 missed heartbeats (30s interval) + 1s buffer
-- This ensures consistency between home screen and online world map counts

-- 1. Update get_online_users_count (home screen dashboard)
CREATE OR REPLACE FUNCTION public.get_online_users_count(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  online_count integer;
BEGIN
  SELECT COUNT(*)
  INTO online_count
  FROM public.user_activity ua
  WHERE ua.is_online = true
    AND ua.last_activity > NOW() - INTERVAL '61 seconds';

  RETURN COALESCE(online_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO anon;

-- 2. Update get_online_users_count_excluding_self (nearby map online count provider)
CREATE OR REPLACE FUNCTION public.get_online_users_count_excluding_self(p_user_id UUID)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  online_count integer;
BEGIN
  SELECT COUNT(*)
  INTO online_count
  FROM public.user_activity ua
  INNER JOIN public.users u ON ua.user_id = u.id
  WHERE ua.is_online = true
    AND ua.last_activity > NOW() - INTERVAL '61 seconds'
    AND ua.user_id != p_user_id
    AND COALESCE(u.user_visibility_setting, false) = true
    AND COALESCE(u.system_visibility_status, 'visible') = 'visible';

  RETURN COALESCE(online_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO anon;

-- 3. Update is_user_truly_visible (visibility check for nearby map)
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
          AND ua.last_activity > NOW() - INTERVAL '61 seconds'
      )
      AND COALESCE(u.user_visibility_setting, false) = TRUE
      AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
    )
  FROM public.users u
  WHERE u.id = p_user_id
), FALSE);
$$;

-- 4. Update get_online_user_counts_by_country (online world map)
-- Change default from 30 seconds to 61 seconds
CREATE OR REPLACE FUNCTION public.get_online_user_counts_by_country(
  p_recent_seconds integer DEFAULT 61
)
RETURNS TABLE (
  country text,
  user_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_seconds integer;
BEGIN
  IF auth.uid() IS NULL AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_seconds := GREATEST(LEAST(COALESCE(p_recent_seconds, 61), 3600), 5);

  RETURN QUERY
  WITH online AS (
    SELECT DISTINCT ua.user_id
    FROM public.user_activity ua
    WHERE ua.is_online = true
      AND ua.last_activity > NOW() - make_interval(secs => v_seconds)
  ),
  latest_session AS (
    SELECT DISTINCT ON (us.user_id)
      us.user_id,
      NULLIF(btrim(COALESCE(us.country, '')), '') AS country
    FROM public.user_session us
    WHERE us.revoked = false
    ORDER BY
      us.user_id,
      us.last_active_at DESC NULLS LAST,
      us.created_at DESC NULLS LAST,
      us.id DESC
  )
  SELECT
    ls.country AS country,
    COUNT(*)::integer AS user_count
  FROM online o
  LEFT JOIN latest_session ls ON ls.user_id = o.user_id
  WHERE ls.country IS NOT NULL
  GROUP BY ls.country
  ORDER BY user_count DESC, ls.country ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country(integer) TO authenticated;
