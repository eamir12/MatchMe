-- =============================================================================
-- READ-ONLY follow-up: profile reminders — who got them, and why not me?
-- =============================================================================
-- Requires no parameters. All SELECTs; nothing is written or claimed.
--
-- Background: the first diagnostic showed the fix IS applied, the automation
-- IS enabled, and actual_sent_count = 2 with updated_at 2026-10-07 05:23 UTC —
-- the RPC has queued 2 reminders since the fix. This script shows WHO received
-- them and shows every currently-eligible candidate (you should be in that
-- list) with the exact reason if you are not.

-- ---------------------------------------------------------------
-- A) The profile_reminder deliveries made so far (most recent 20)
-- ---------------------------------------------------------------
SELECT 'A_recent_deliveries' AS section,
       u.email, u.name, d.created_at
FROM public.admin_broadcast_deliveries d
JOIN public.admin_broadcasts b ON b.id = d.broadcast_id
JOIN public.users u ON u.id = d.user_id
WHERE b.automation_type = 'profile_reminder'
ORDER BY d.created_at DESC
LIMIT 20;

-- ---------------------------------------------------------------
-- B) Every user with an incomplete profile right now, with the exact
--    eligibility facts the claim function checks:
--      is_admin (admins are NEVER reminded),
--      hours since the app was closed (first reminder due at >= 1h),
--      a non-revoked session WITH a non-empty FCM token,
--      push prefs (defaults true),
--      the 2-per-day admin_broadcast frequency guard,
--      and the existing reminder_state row (NULL = never claimed).
-- ---------------------------------------------------------------
WITH latest_session AS (
  SELECT DISTINCT ON (us.user_id)
    us.user_id, us.revoked, us.platform, us.last_active_at,
    COALESCE(NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''), '') AS fcm_token
  FROM public.user_session us
  ORDER BY us.user_id, us.last_active_at DESC NULLS LAST
),
cand AS (
  SELECT
    u.id, u.email, u.name,
    u.is_admin,
    round(EXTRACT(EPOCH FROM (now() - ua.last_activity)) / 3600.0, 2) AS hours_app_closed,
    ls.revoked AS latest_session_revoked,
    ls.platform,
    ls.last_active_at,
    (ls.fcm_token = '') AS missing_fcm_token,
    COALESCE((u.notification_preferences->'global_methods'->>'push')::boolean, true) AS push_enabled,
    COALESCE(
      (u.notification_preferences->'matrix'->'admin_announcements'->>'push')::boolean,
      (u.notification_preferences->>'enable_admin_notifications')::boolean, true) AS admin_announcements_push,
    (
      SELECT COUNT(*) FROM public.notification_queue q
      WHERE q.user_id = u.id AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) AS admin_broadcast_pushes_last_24h,
    s.stage AS reminder_stage,
    s.last_sent_at AS last_reminder_sent_at
  FROM public.users u
  JOIN public.user_activity ua ON ua.user_id = u.id
  LEFT JOIN latest_session ls ON ls.user_id = u.id
  LEFT JOIN public.profile_reminder_state s ON s.user_id = u.id
  WHERE COALESCE(u.is_profile_complete, false) = false
    AND COALESCE(u.is_admin, false) = false
)
SELECT 'B_candidates' AS section,
       email, name,
       hours_app_closed,
       CASE
         WHEN latest_session_revoked IS NULL OR latest_session_revoked THEN 'NO reachable session'
         WHEN missing_fcm_token THEN 'NO fcm token on session'
         WHEN hours_app_closed IS NULL THEN 'no user_activity row'
         WHEN hours_app_closed < 1 THEN 'app closed < 1h (not due yet)'
         WHEN NOT push_enabled THEN 'push disabled'
         WHEN NOT admin_announcements_push THEN 'admin announcements push disabled'
         WHEN admin_broadcast_pushes_last_24h >= 2 THEN 'frequency guard: 2 admin_broadcast pushes in last 24h'
         ELSE 'ELIGIBLE - should be claimed on next tick'
       END AS status,
       reminder_stage,
       last_reminder_sent_at
FROM cand
ORDER BY hours_app_closed DESC NULLS LAST
LIMIT 50;

-- ---------------------------------------------------------------
-- C) The most recent admin_broadcast notifications in the queue
--    (status pending/processing/sent/failed + failure_reason), so we
--    can see whether the 2 queued reminders were actually SENT via FCM.
-- ---------------------------------------------------------------
SELECT 'C_recent_admin_broadcast_queue' AS section,
       q.created_at, q.status, q.attempts, q.max_attempts,
       LEFT(COALESCE(q.failure_reason, ''), 120) AS failure_reason,
       u.email, q.title
FROM public.notification_queue q
JOIN public.users u ON u.id = q.user_id
WHERE (q.data->>'type') = 'admin_broadcast'
ORDER BY q.created_at DESC
LIMIT 20;

-- How to read:
--   A) If your own email appears here, the reminder WAS queued for you and
--      the problem moves to delivery: check section C for status 'sent' vs
--      'failed' (and failure_reason), whether the device had internet /
--      FCM registration, and that the app was closed when it fired.
--   B) Find your account's row. The status column names the exact reason
--      you are not being claimed. NOTE: is_admin = true accounts are
--      filtered out of section B entirely — if your test account is an
--      admin, it will never receive reminders BY DESIGN.
--   C) 'sent' rows mean FCM accepted the message; if the device still
--      showed nothing, the token was stale or the app build lacks the
--      fixed push pipeline (the FCM fix still awaits the next release
--      build on some builds).
