-- Fix online world map undercount: prefer the latest session WITH a country.
--
-- Problem: get_online_user_counts_by_country* builds latest_session with
--   DISTINCT ON (user_id) ORDER BY last_active_at DESC.
-- A user with several non-revoked sessions (e.g. Android + web, or a fresh
-- bootstrap registration without GPS followed by a map registration with
-- GPS) is represented by ONLY the newest row. When that newest row has a
-- NULL/empty country (GPS not ready, permission denied, cold-start register
-- without coordinates), the user is filtered out by WHERE country IS NOT
-- NULL even though an older session of the SAME user has a valid country.
-- Result: 2 users online, map shows 1 ("online, but not on map").
--
-- Fix: order latest_session so a row WITH a country wins over a newer row
-- without one. Only users with NO country on ANY non-revoked session stay
-- excluded (they cannot be placed on a country map).
-- This fix can only ADD previously-hidden users; it never removes anyone.

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
      -- Prefer the newest session WITH a country over a newer one without.
      (NULLIF(btrim(COALESCE(us.country, '')), '') IS NOT NULL) DESC,
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

COMMENT ON FUNCTION public.get_online_user_counts_by_country(integer) IS
  'Returns online user counts grouped by country. When a user has several sessions, the newest session WITH a country wins so a country-less session can never hide a valid country.';

CREATE OR REPLACE FUNCTION public.get_online_user_counts_by_country_excluding_self(
  p_user_id uuid,
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
      AND (p_user_id IS NULL OR ua.user_id != p_user_id)
  ),
  latest_session AS (
    SELECT DISTINCT ON (us.user_id)
      us.user_id,
      NULLIF(btrim(COALESCE(us.country, '')), '') AS country
    FROM public.user_session us
    WHERE us.revoked = false
    ORDER BY
      us.user_id,
      -- Prefer the newest session WITH a country over a newer one without.
      (NULLIF(btrim(COALESCE(us.country, '')), '') IS NOT NULL) DESC,
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

GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country_excluding_self(uuid, integer) TO authenticated;
