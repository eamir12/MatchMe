-- Include users without a country in online world map counts
-- Shows them as "UNKNOWN" so they appear on the map immediately
-- Once their country is set via IP geolocation, they'll move to the correct country bucket

BEGIN;

-- Update get_online_user_counts_by_country to include users without a country
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
    COALESCE(ls.country, 'UNKNOWN') AS country,
    COUNT(*)::integer AS user_count
  FROM online o
  LEFT JOIN latest_session ls ON ls.user_id = o.user_id
  GROUP BY COALESCE(ls.country, 'UNKNOWN')
  HAVING COUNT(*) > 0
  ORDER BY user_count DESC, country ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country(integer) TO authenticated;

COMMENT ON FUNCTION public.get_online_user_counts_by_country(integer) IS 
  'Returns online user counts grouped by country, including users without a country as "UNKNOWN"';

COMMIT;
