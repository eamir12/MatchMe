-- =============================================================================
-- READ-ONLY: why did the artificial trigger not claim me?
-- =============================================================================

-- 1) THE CLOSURE CLOCK — this is what the claim function requires to be
--    stale by >= 3 minutes (0.05h). If last_activity is advancing (seconds
--    old), something is still heartbeating and the system does NOT consider
--    the app closed — no reminder can ever fire.
SELECT 'closure_clock' AS section,
       ua.last_activity,
       round(EXTRACT(EPOCH FROM (now() - ua.last_activity)) / 60.0, 1) AS minutes_since_heartbeat,
       us.last_active_at,
       round(EXTRACT(EPOCH FROM (now() - us.last_active_at)) / 60.0, 1) AS minutes_since_session_activity
FROM public.users u
JOIN public.user_activity ua ON ua.user_id = u.id
LEFT JOIN LATERAL (
  SELECT us.last_active_at
  FROM public.user_session us
  WHERE us.user_id = u.id AND us.revoked = false
  ORDER BY us.last_active_at DESC NULLS LAST
  LIMIT 1
) us ON true
WHERE u.email = 'eranamir.aci@gmail.com';

-- 2) Did a claim happen after all? (a row here with last_sent_at in the
--    last few minutes means the claim DID fire — then the failure is in
--    the queue function / guards, not the claim)
SELECT 'reminder_state' AS section, *
FROM public.profile_reminder_state
WHERE user_id = (SELECT id FROM public.users WHERE email = 'eranamir.aci@gmail.com');

-- 3) Sanity: is the account still matching every claim gate?
SELECT 'claim_gates' AS section,
       u.is_profile_complete,
       u.is_admin,
       COALESCE((u.notification_preferences->'global_methods'->>'push')::boolean, true) AS push_enabled,
       COALESCE(
         (u.notification_preferences->'matrix'->'admin_announcements'->>'push')::boolean,
         (u.notification_preferences->>'enable_admin_notifications')::boolean, true) AS admin_announcements_push,
       (SELECT COUNT(*) FROM public.user_session s
         WHERE s.user_id = u.id AND s.revoked = false
           AND NULLIF(btrim(COALESCE(s.metadata->>'fcm_token','')), '') IS NOT NULL) AS reachable_sessions
FROM public.users u
WHERE u.email = 'eranamir.aci@gmail.com';

-- 4) Are cron ticks still dispatching? (last 5)
SELECT 'cron_recent' AS section, status, start_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'matchme-cron-jobs')
ORDER BY start_time DESC
LIMIT 5;

-- How to read:
--   * closure_clock.minutes_since_heartbeat SMALL and shrinking on re-run
--     => the heartbeat is STILL RUNNING (foreground service / background
--     location keeps user_activity.last_activity fresh even after swiping
--     the app away) — the system never sees the app as closed. This is the
--     prime suspect.
--   * reminder_state has a fresh row => the claim DID fire and the problem
--     is downstream in the queue function.
--   * claim_gates: is_profile_complete must be false (t), is_admin must be
--     false (f), push flags true, reachable_sessions >= 1.
