-- =============================================================================
-- ARTIFICIAL PROFILE-REMINDER TRIGGER (developer test)
-- =============================================================================
-- Makes the real cron automation fire a "Finish your profile" reminder for
-- eranamir.aci@gmail.com within ~3 minutes of closing the app, instead of
-- waiting 1 hour. Everything below runs the REAL end-to-end path:
-- pg_cron -> cron-jobs edge fn -> queue RPC -> claim -> FCM.
--
-- WHY THE EXTRA STEPS: the queue function has two anti-duplicate guards that
-- would silently skip you today (you already got the 02:02 reminder + test
-- broadcasts):
--   a) per-day delivery dedupe: skips if a delivery row for THIS broadcast +
--      you was created today
--   b) 2/day frequency guard: skips if >= 2 'admin_broadcast' queue rows for
--      you in the last 24h
-- Steps 2-3 delete exactly those already-sent test rows. Side effects: the
-- broadcast's actual_sent_count is not decremented and those delivery stats
-- rows are gone — acceptable for a dev test.
--
-- Order matters. Run STEP 1-4, then close the app (fully swipe it away),
-- wait 3+ minutes, check the device. Then run STEP 5 to restore config.

-- ---------------------------------------------------------------
-- STEP 1: shrink the first reminder offset to 3 minutes (0.05 h)
-- ---------------------------------------------------------------
UPDATE public.app_config
SET config_value = '[0.05]'::jsonb
WHERE config_key = 'notifications.profile_reminder.offsets_hours';

-- ---------------------------------------------------------------
-- STEP 2: clear today's delivery row for this broadcast + you
--         (defeats the per-day dedupe)
-- ---------------------------------------------------------------
DELETE FROM public.admin_broadcast_deliveries
WHERE broadcast_id = 'd475207b-b42f-4b6f-bdef-9fe8e25ba134'
  AND user_id = (SELECT id FROM public.users WHERE email = 'eranamir.aci@gmail.com')
  AND created_at >= date_trunc('day', now());

-- ---------------------------------------------------------------
-- STEP 3: clear your last-24h admin_broadcast queue rows
--         (defeats the 2/day frequency guard; all of them are
--         already-status 'sent' test rows)
-- ---------------------------------------------------------------
DELETE FROM public.notification_queue
WHERE user_id = (SELECT id FROM public.users WHERE email = 'eranamir.aci@gmail.com')
  AND (data->>'type') = 'admin_broadcast'
  AND created_at >= now() - interval '1 day';

-- ---------------------------------------------------------------
-- STEP 4 (optional but cleaner): reset your reminder stage so the
--         send comes through as a fresh stage-1 claim
-- ---------------------------------------------------------------
DELETE FROM public.profile_reminder_state
WHERE user_id = (SELECT id FROM public.users WHERE email = 'eranamir.aci@gmail.com');

-- ---------------------------------------------------------------
-- Verify setup (optional, read-only): guards cleared + config set
-- ---------------------------------------------------------------
SELECT 'config' AS check, config_value::text
FROM public.app_config
WHERE config_key = 'notifications.profile_reminder.offsets_hours'
UNION ALL
SELECT 'deliveries_today',
       COUNT(*)::text
FROM public.admin_broadcast_deliveries
WHERE broadcast_id = 'd475207b-b42f-4b6f-bdef-9fe8e25ba134'
  AND user_id = (SELECT id FROM public.users WHERE email = 'eranamir.aci@gmail.com')
  AND created_at >= date_trunc('day', now())
UNION ALL
SELECT 'queue_rows_24h',
       COUNT(*)::text
FROM public.notification_queue
WHERE user_id = (SELECT id FROM public.users WHERE email = 'eranamir.aci@gmail.com')
  AND (data->>'type') = 'admin_broadcast'
  AND created_at >= now() - interval '1 day'
UNION ALL
SELECT 'reminder_state_rows',
       COUNT(*)::text
FROM public.profile_reminder_state
WHERE user_id = (SELECT id FROM public.users WHERE email = 'eranamir.aci@gmail.com');
-- Expected: config = [0.05], and 0 for the other three.

-- THEN, ON THE DEVICE:
--   1) Fully close the app (swipe it away from recents).
--   2) Wait at least 3 minutes (the app must stay closed so the
--      heartbeat stops and the closure clock runs).
--   3) The next cron tick (every minute) claims you and queues the push —
--      expect the "Finish your profile" notification on the device.
--   4) If nothing arrives within ~5 minutes, see the CHECK SQL below.

-- ---------------------------------------------------------------
-- STEP 5: AFTER THE TEST — restore the real intervals
-- ---------------------------------------------------------------
-- UPDATE public.app_config
-- SET config_value = '[1, 5]'::jsonb
-- WHERE config_key = 'notifications.profile_reminder.offsets_hours';

-- ---------------------------------------------------------------
-- CHECK (read-only) if nothing arrived:
-- ---------------------------------------------------------------
-- SELECT q.created_at, q.status, q.attempts,
--        LEFT(COALESCE(q.failure_reason, ''), 120) AS failure_reason
-- FROM public.notification_queue q
-- WHERE q.user_id = (SELECT id FROM public.users WHERE email = 'eranamir.aci@gmail.com')
--   AND (q.data->>'type') = 'admin_broadcast'
-- ORDER BY q.created_at DESC
-- LIMIT 5;
-- A fresh row with status 'sent' means FCM accepted it and the failure is
-- device-side again (unlikely — your broadcast tests proved display works).
-- NO new row means the claim skipped you: most likely the app wasn't fully
-- closed (heartbeat kept running) or wasn't closed for the full 3 minutes.
