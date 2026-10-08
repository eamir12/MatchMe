-- =============================================================================
-- READ-ONLY diagnostic: why am I not getting "finish your profile" reminders?
-- =============================================================================
-- Safe to run as-is in the Supabase SQL Editor: every statement is a SELECT
-- (or a catalog read). Nothing is written, claimed, or queued.
--
-- Set this one value, then run the whole script:
--
--   1) YOUR EMAIL OR USER UUID (the account with the unfinished profile)

WITH params AS (
  SELECT 'you@example.com'::text AS me_email_or_id
),

-- ---------------------------------------------------------------
-- 1) Your account + the four hard eligibility gates from
--    claim_profile_reminder_candidates():
--      a. is_profile_complete = false
--      b. is_admin = false
--      c. push enabled (global_methods.push, default true)
--      d. admin announcements push enabled (default true)
-- ---------------------------------------------------------------
me AS (
  SELECT u.*
  FROM public.users u, params p
  WHERE u.email = p.me_email_or_id
     OR u.id::text = p.me_email_or_id
  LIMIT 1
),
q1 AS (
  SELECT
    id,
    email,
    name,
    is_profile_complete                                   AS gate_a_profile_complete_false,
    is_admin                                              AS gate_b_is_admin,
    COALESCE((notification_preferences->'global_methods'->>'push')::boolean, true)
                                                          AS gate_c_push_enabled,
    COALESCE(
      (notification_preferences->'matrix'->'admin_announcements'->>'push')::boolean,
      (notification_preferences->>'enable_admin_notifications')::boolean, true)
                                                          AS gate_d_admin_announcements_push,
    preferred_language
  FROM me
),

-- ---------------------------------------------------------------
-- 2) The closure clock: a reminder is due only after the app has
--    been CLOSED (user_activity.last_activity not advancing) for
--    at least the first offset (default 1 hour).
-- ---------------------------------------------------------------
q2 AS (
  SELECT
    ua.user_id,
    ua.last_activity,
    round(EXTRACT(EPOCH FROM (now() - ua.last_activity)) / 3600.0, 2) AS hours_since_last_activity,
    (EXTRACT(EPOCH FROM (now() - ua.last_activity)) / 3600.0) >= 1.0    AS first_offset_reached
  FROM public.user_activity ua
  JOIN me m ON m.id = ua.user_id
),

-- ---------------------------------------------------------------
-- 3) Reachability: a NON-REVOKED session whose metadata carries a
--    non-empty fcm_token. No token => the claim function skips you.
-- ---------------------------------------------------------------
q3 AS (
  SELECT
    us.user_id,
    us.revoked,
    us.platform,
    us.last_active_at,
    COALESCE(NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''), '') = '' AS missing_fcm_token,
    LEFT(COALESCE(us.metadata->>'fcm_token', ''), 12) || '…'                       AS fcm_token_prefix
  FROM public.user_session us
  JOIN me m ON m.id = us.user_id
  ORDER BY us.last_active_at DESC NULLS LAST
),

-- ---------------------------------------------------------------
-- 4) Your reminder stage state (empty row = you were never claimed).
-- ---------------------------------------------------------------
q4 AS (
  SELECT s.*
  FROM public.profile_reminder_state s
  JOIN me m ON m.id = s.user_id
),

-- ---------------------------------------------------------------
-- 5) Is the FIXED version of claim_profile_reminder_candidates
--    live in the DB? The fix migration (20262097000000) added BOTH
--    markers below. If either is missing, the cron RPC is still
--    failing (42702 ambiguous "user_id" / 42804 numeric vs double
--    precision) and NOBODY gets reminders — this is the top suspect.
-- ---------------------------------------------------------------
q5 AS (
  SELECT
    p.proname,
    (p.prosrc LIKE '%#variable_conflict use_column%')                    AS has_fix_variable_conflict,
    (p.prosrc LIKE '%::double precision AS hours_closed%')               AS has_fix_double_precision_cast,
    (p.prosrc LIKE '%#variable_conflict use_column%')
      AND (p.prosrc LIKE '%::double precision AS hours_closed%')         AS fix_fully_applied
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'claim_profile_reminder_candidates'
),

-- ---------------------------------------------------------------
-- 6) The automation row the cron loop looks for: an admin_broadcasts
--    row with automation_type='profile_reminder' AND
--    automation_enabled=true. Missing or disabled => nothing fires.
-- ---------------------------------------------------------------
q6 AS (
  SELECT id, title, message, automation_enabled, automation_type, status,
         actual_sent_count, created_at, updated_at
  FROM public.admin_broadcasts
  WHERE automation_type = 'profile_reminder'
),

-- ---------------------------------------------------------------
-- 7) Config switches and intervals.
-- ---------------------------------------------------------------
q7 AS (
  SELECT config_key, config_value
  FROM public.app_config
  WHERE config_key LIKE 'notifications.profile_reminder.%'
  ORDER BY config_key
),

-- ---------------------------------------------------------------
-- 8) Cron plumbing: schedule present + last 15 run outcomes.
--    (A 'succeeded' here only means the HTTP POST was dispatched;
--    check Edge Function logs for the cron-jobs task
--    'profile_completion_reminders' for the real outcome.)
-- ---------------------------------------------------------------
q8a AS (
  SELECT jobid, jobname, schedule, active
  FROM cron.job
  WHERE jobname = 'matchme-cron-jobs'
),
q8b AS (
  SELECT status, return_message, start_time, end_time
  FROM cron.job_run_details
  WHERE jobid = (SELECT jobid FROM q8a LIMIT 1)
  ORDER BY start_time DESC
  LIMIT 15
),

-- ---------------------------------------------------------------
-- 9) Did anything ever get queued/delivered for you?
-- ---------------------------------------------------------------
q9a AS (
  SELECT q.created_at, q.status, q.data->>'type' AS notif_type, q.data->>'action_url' AS action_url
  FROM public.notification_queue q
  JOIN me m ON m.id = q.user_id
  ORDER BY q.created_at DESC
  LIMIT 10
),
q9b AS (
  SELECT d.created_at, d.broadcast_id, b.title
  FROM public.admin_broadcast_deliveries d
  JOIN me m ON m.id = d.user_id
  LEFT JOIN public.admin_broadcasts b ON b.id = d.broadcast_id
  ORDER BY d.created_at DESC
  LIMIT 10
)

-- ============================ RESULTS ============================
SELECT '1_account_gates'    AS section, row_to_json(x)::text AS result FROM (SELECT * FROM q1) x
UNION ALL SELECT '2_closure_clock',  row_to_json(x)::text FROM (SELECT * FROM q2) x
UNION ALL SELECT '3_sessions',       row_to_json(x)::text FROM (SELECT * FROM q3) x
UNION ALL SELECT '4_reminder_state', row_to_json(x)::text FROM (SELECT * FROM q4) x
UNION ALL SELECT '5_fix_applied',    row_to_json(x)::text FROM (SELECT * FROM q5) x
UNION ALL SELECT '6_automation_row', row_to_json(x)::text FROM (SELECT * FROM q6) x
UNION ALL SELECT '7_config',         row_to_json(x)::text FROM (SELECT * FROM q7) x
UNION ALL SELECT '8a_cron_schedule', row_to_json(x)::text FROM (SELECT * FROM q8a) x
UNION ALL SELECT '8b_cron_last_runs',row_to_json(x)::text FROM (SELECT * FROM q8b) x
UNION ALL SELECT '9a_my_queue',      row_to_json(x)::text FROM (SELECT * FROM q9a) x
UNION ALL SELECT '9b_my_deliveries', row_to_json(x)::text FROM (SELECT * FROM q9b) x
ORDER BY section;

-- How to read the results:
--   * section 5_fix_applied: fix_fully_applied must be TRUE. If FALSE, run
--     supabase/migrations/20262097000000_fix_profile_reminder_claim_ambiguous_columns.sql,
--     then .tmp/dryrun_20262097000000_fix_profile_reminder.sql to confirm.
--   * section 6: automation_enabled must be true on the profile_reminder row.
--   * sections 1-3: all four gates must pass and the FCM token must exist.
--   * section 2: first_offset_reached must be TRUE — the app must have been
--     closed for >= 1 hour (while the app runs, last_activity keeps
--     advancing and NO reminder is due; that is by design).
--   * section 8b: recurring failures point at the cron-jobs edge function
--     (not deployed / wrong secret) rather than the reminder SQL itself.
