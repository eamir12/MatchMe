-- Require country for online world map - exclude users without GPS-based country
-- GPS coordinates are the only reliable source (IP can be VPN spoofed)

BEGIN;

-- Update get_online_user_counts_by_country to exclude users without a country
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
      us.id as session_id,
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
  WHERE ls.country IS NOT NULL  -- Exclude users without GPS-based country
  GROUP BY ls.country
  HAVING COUNT(*) > 0
  ORDER BY user_count DESC, ls.country ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country(integer) TO authenticated;

COMMENT ON FUNCTION public.get_online_user_counts_by_country(integer) IS 
  'Returns online user counts grouped by country. Only includes users with valid GPS-based country.';

COMMIT;
