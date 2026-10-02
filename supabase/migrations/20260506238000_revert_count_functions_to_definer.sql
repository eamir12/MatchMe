-- Revert online count functions back to SECURITY DEFINER
-- These functions do complex joins and need elevated privileges
-- We will document these as intentional security warnings

-- Drop functions first
DROP FUNCTION IF EXISTS public.get_online_users_count(uuid);
DROP FUNCTION IF EXISTS public.get_online_users_count_excluding_self(uuid);
DROP FUNCTION IF EXISTS public.get_online_user_counts_by_country(integer);
DROP FUNCTION IF EXISTS public.health_check();

-- 1. Restore get_online_users_count as SECURITY DEFINER
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

-- 2. Restore get_online_users_count_excluding_self as SECURITY DEFINER
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

-- 3. Restore get_online_user_counts_by_country as SECURITY DEFINER
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

-- 4. Restore health_check as SECURITY DEFINER
CREATE OR REPLACE FUNCTION public.health_check()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN jsonb_build_object('ok', true, 'checked_at', now());
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM, 'checked_at', now());
END;
$$;

GRANT EXECUTE ON FUNCTION public.health_check() TO anon;
GRANT EXECUTE ON FUNCTION public.health_check() TO authenticated;

-- Verify the functions are now SECURITY DEFINER
SELECT
    proname as function_name,
    prosecdef as is_security_definer
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
    AND proname IN ('get_online_users_count', 'get_online_users_count_excluding_self', 'get_online_user_counts_by_country', 'health_check')
ORDER BY proname;