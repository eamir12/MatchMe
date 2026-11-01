-- Migration: harden the minute dispatcher timeout and lock down an internal
-- enqueue helper.
--
-- 1) cron.schedule created matchme-cron-jobs without
--    timeout_milliseconds, so pg_net aborted at its 5 s default while the
--    edge function kept running. Roughly one tick in three logged a false
--    "timed_out" in net._http_response (no work was lost). Re-scheduling the
--    stable name updates the job in place with a 30 s timeout, matching the
--    instant-dispatch RPC.
--
-- 2) queue_fcm_notification is an internal enqueue helper with no caller
--    identity checks. Both overloads were executable by `authenticated`, so
--    any signed-in user could queue a push addressed to any user_id/token.
--    Only server-side code (SECURITY DEFINER functions, edge functions on
--    service_role) calls it. Restrict both overloads to service_role.

BEGIN;

SELECT cron.schedule(
  'matchme-cron-jobs',
  '* * * * *',
  $$
  SELECT net.http_post(
    url := (
      SELECT base_url || '/functions/v1/cron-jobs'
      FROM private.cron_job_config
      WHERE id = 1
      LIMIT 1
    ),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        SELECT anon_key
        FROM private.cron_job_config
        WHERE id = 1
        LIMIT 1
      ),
      'x-matchme-internal', COALESCE((
        SELECT internal_secret
        FROM private.cron_job_config
        WHERE id = 1
        LIMIT 1
      ), '')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  ) AS request_id;
  $$
);

REVOKE ALL ON FUNCTION public.queue_fcm_notification(uuid, text, text, text, jsonb, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.queue_fcm_notification(uuid, text, text, text, jsonb, text)
  TO service_role;

REVOKE ALL ON FUNCTION public.queue_fcm_notification(text, text, text, jsonb, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.queue_fcm_notification(text, text, text, jsonb, text)
  TO service_role;

COMMIT;
