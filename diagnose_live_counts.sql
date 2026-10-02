-- Diagnose admin LIVE online/visible undercount.
-- Run whole script in Supabase Dashboard > SQL Editor (as postgres) and
-- paste back ALL result grids.
-- Thresholds mirror the live RPCs: online = heartbeat within 61s,
-- visible = is_user_truly_visible() (online + visibility + location <= 15m).
-- Since migration 20262004 the LIVE counts INCLUDE admin accounts.

-- ── 0. Deployment checks: are the fixed functions/indexes live? ──
SELECT
  (SELECT position('generated_at' IN pg_get_functiondef(o.oid)) > 0
     FROM pg_proc o WHERE o.proname = 'admin_get_realtime_user_counts'
     ORDER BY o.oid DESC LIMIT 1) AS realtime_counts_is_new_version,
  (SELECT position('COALESCE(u.is_admin' IN pg_get_functiondef(o.oid)) = 0
     FROM pg_proc o WHERE o.proname = 'admin_get_realtime_user_counts'
     ORDER BY o.oid DESC LIMIT 1) AS realtime_counts_includes_admins,
  (SELECT position('LATERAL' IN pg_get_functiondef(o.oid)) > 0
     FROM pg_proc o WHERE o.proname = 'admin_get_dashboard_drilldown'
     ORDER BY o.oid DESC LIMIT 1) AS drilldown_has_lateral_fix,
  EXISTS (SELECT 1 FROM pg_indexes
           WHERE schemaname = 'public' AND indexname = 'idx_user_locations_user_id_unique'
         ) AS locations_unique_index_present,
  (SELECT count(*) FROM public.users
    WHERE coalesce(user_visibility_setting, false) = true
      AND coalesce(system_visibility_status, 'visible')
          IN ('gps_problem', 'network_offline', 'offline', 'invisible_rules')
  ) AS users_with_dead_visibility_status;

-- ── 1. Live counts, replicated without the admin auth-check ──
SELECT
  (SELECT coalesce(count(DISTINCT ua.user_id), 0)::int
     FROM public.user_activity ua
     JOIN public.users u ON u.id = ua.user_id
    WHERE ua.is_online = true
      AND ua.last_activity > now() - interval '61 seconds') AS online_now,
  (SELECT count(DISTINCT u.id)::int
     FROM public.users u
    WHERE public.is_user_truly_visible(u.id) = true) AS visible_now;

-- ── 2. Per-user breakdown (everyone active in the last 24h) ──
WITH recent AS (
  SELECT DISTINCT ua.user_id
    FROM public.user_activity ua
   WHERE ua.last_activity > now() - interval '24 hours'
)
SELECT
  left(r.user_id::text, 8) AS id8,
  coalesce(u.name, '(no name)') AS name,
  coalesce(u.is_admin, false) AS is_admin,
  ua.is_online AS flag_online,
  round(extract(epoch FROM (now() - ua.last_activity)))::int AS activity_age_s,
  (SELECT count(*) FROM public.user_session s
    WHERE s.user_id = r.user_id AND s.revoked = false) AS active_sessions,
  (SELECT count(*) FROM public.user_session s
    WHERE s.user_id = r.user_id AND s.revoked = true) AS revoked_sessions,
  coalesce(u.user_visibility_setting, false) AS vis_setting,
  coalesce(u.system_visibility_status, 'visible') AS sys_status,
  round(extract(epoch FROM (now() - ul.updated_at)))::int AS loc_age_s,
  public.is_user_truly_visible(r.user_id) AS truly_visible,
  -- Would the LIVE cards count this user? (admins included since 20262004)
  (coalesce(ua.is_online, false)
     AND ua.last_activity > now() - interval '61 seconds') AS counted_online,
  public.is_user_truly_visible(r.user_id) AS counted_visible,
  -- Exact exclusion reason for ONLINE:
  CASE
    WHEN ua.user_id IS NULL THEN 'offline: no user_activity row (heartbeat never reached DB)'
    WHEN coalesce(ua.is_online, false) = false
         AND ua.last_activity > now() - interval '120 seconds'
         AND NOT EXISTS (SELECT 1 FROM public.user_session s
                          WHERE s.user_id = r.user_id AND s.revoked = false)
         AND EXISTS (SELECT 1 FROM public.user_session s
                      WHERE s.user_id = r.user_id AND s.revoked = true)
      THEN 'offline: SESSION GATE — fresh heartbeat but is_online=false, 0 active + revoked sessions exist (re-login / registerSession failing?)'
    WHEN coalesce(ua.is_online, false) = false
      THEN 'offline: is_online=false (logged out or reaped by cleanup)'
    WHEN ua.last_activity <= now() - interval '61 seconds'
      THEN 'offline: stale heartbeat (no ping for >61s — app backgrounded/killed/throttled?)'
    ELSE 'counts as online'
  END AS online_reason,
  -- Exact exclusion reason for VISIBLE (admins included since 20262004):
  CASE
    WHEN public.is_user_truly_visible(r.user_id) THEN 'counts as visible'
    WHEN coalesce(u.user_visibility_setting, false) = false
      THEN 'not visible: user_visibility_setting=false (toggle OFF)'
    WHEN coalesce(u.system_visibility_status, 'visible') <> 'visible'
      THEN 'not visible: system_visibility_status=' || coalesce(u.system_visibility_status, 'visible')
    WHEN NOT (coalesce(ua.is_online, false) AND ua.last_activity > now() - interval '61 seconds')
      THEN 'not visible: no fresh heartbeat (>61s or offline flag)'
    WHEN ul.updated_at IS NULL
      THEN 'not visible: NO user_locations row at all (GPS/permission/upload never delivered?)'
    WHEN ul.updated_at <= now() - interval '15 minutes'
      THEN 'not visible: stale location (last upload >15m ago)'
    ELSE 'not visible: unknown (see flags above)'
  END AS visible_reason
FROM recent r
JOIN public.users u ON u.id = r.user_id
LEFT JOIN public.user_activity ua ON ua.user_id = r.user_id
LEFT JOIN LATERAL (
  SELECT l.updated_at
    FROM public.user_locations l
   WHERE l.user_id = r.user_id
   ORDER BY l.updated_at DESC NULLS LAST
   LIMIT 1
) ul ON true
ORDER BY ua.last_activity DESC NULLS LAST;

-- ── 3. Logged-in sessions with NO activity row at all (heartbeat never arrives) ──
SELECT left(s.user_id::text, 8) AS id8,
       coalesce(u.name, '(no name)') AS name,
       count(*) FILTER (WHERE s.revoked = false)::int AS active_sessions,
       max(s.last_active_at) AS latest_session_activity
FROM public.user_session s
LEFT JOIN public.users u ON u.id = s.user_id
WHERE s.user_id NOT IN (SELECT ua.user_id FROM public.user_activity ua)
GROUP BY s.user_id, u.name
ORDER BY latest_session_activity DESC NULLS LAST
LIMIT 20;
