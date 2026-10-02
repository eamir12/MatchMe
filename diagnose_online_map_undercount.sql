-- Diagnostic: why does the online world map show 1 when 2 users are online?
-- Run this in Supabase Dashboard > SQL Editor.
-- It shows, for every recently-active user:
--   1. user_activity freshness (is the 61s window excluding them?)
--   2. ALL non-revoked sessions per user (does the newest lack country while an older one has it?)
--   3. What the map RPCs actually return.
-- The most common root cause is (2): latest_session picks the newest
-- last_active_at row even when its country IS NULL, shadowing a valid
-- country on another device/session of the same user.

-- 1. Who is considered "recently active" by the 61s window?
SELECT
  ua.user_id,
  ua.is_online,
  ua.last_activity,
  EXTRACT(EPOCH FROM (NOW() - ua.last_activity))::int AS seconds_ago,
  CASE
    WHEN ua.is_online = true AND ua.last_activity > NOW() - INTERVAL '61 seconds'
    THEN 'COUNTED as online'
    ELSE 'EXCLUDED from online count'
  END AS online_status
FROM public.user_activity ua
ORDER BY ua.last_activity DESC
LIMIT 20;

-- 2. All non-revoked sessions per recently-active user, newest first.
-- If the first row per user has NULL/empty country but a later row has a
-- country, the map RPC (before the fix) hides that user entirely.
SELECT
  us.user_id,
  us.platform,
  us.device_id,
  NULLIF(btrim(COALESCE(us.country, '')), '') AS country,
  us.revoked,
  us.last_active_at,
  EXTRACT(EPOCH FROM (NOW() - us.last_active_at))::int AS session_seconds_ago,
  ROW_NUMBER() OVER (
    PARTITION BY us.user_id
    ORDER BY us.last_active_at DESC NULLS LAST, us.created_at DESC NULLS LAST, us.id DESC
  ) AS recency_rank,
  ROW_NUMBER() OVER (
    PARTITION BY us.user_id
    ORDER BY
      (NULLIF(btrim(COALESCE(us.country, '')), '') IS NOT NULL) DESC,
      us.last_active_at DESC NULLS LAST, us.created_at DESC NULLS LAST, us.id DESC
  ) AS country_first_rank
FROM public.user_session us
WHERE us.revoked = false
  AND us.user_id IN (
    SELECT ua.user_id FROM public.user_activity ua
    WHERE ua.is_online = true
      AND ua.last_activity > NOW() - INTERVAL '5 minutes'
  )
ORDER BY us.user_id, recency_rank;

-- 3. What the home-screen counter sees (no country requirement).
SELECT public.get_online_others_count(auth.uid()) AS others_excluding_me;

-- 4. What the map markers see (requires a country on the latest session).
-- Pass one of the two online user IDs explicitly to avoid auth.uid() confusion:
-- SELECT * FROM public.get_online_user_counts_by_country_excluding_self('PASTE_USER_ID_HERE'::uuid);
SELECT * FROM public.get_online_user_counts_by_country_excluding_self(auth.uid());

-- 5. Inclusive variant (includes caller) for comparison.
SELECT * FROM public.get_online_user_counts_by_country(61);
