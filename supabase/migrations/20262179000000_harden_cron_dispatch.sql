-- Cron dispatch hardening.
--
-- Problems fixed:
--   * notification_queue rows stuck in 'processing' were never recovered.
--     A row is claimed optimistically, then the edge invocation can die
--     (wall clock, isolate eviction, network) before it writes the final
--     status. Those rows were invisible to the drain forever and the member
--     never got the push. A bounded recovery sweep now requeues them (or
--     marks them failed when attempts are exhausted).
--   * cleanup_edge_function_invocations() ran on every tick and was
--     SECURITY DEFINER without a pinned search_path or a service-role guard.
--     It is now guarded, and the edge task claims it once per day.
--   * Dashboard-created jobs that duplicate migration-owned work are removed:
--       delete-job-run-details        -> prune_cron_job_run_details* (30d)
--       prune_edge_function_invocations -> edge cleanup task (daily)
--   * If the old prune job and the runid-bounded replacement both exist, the
--     old one is unscheduled so cron history is not pruned twice a day.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Recover notification_queue rows whose 'processing' claim was abandoned.
--    attempts was already incremented at claim time, so an exhausted row goes
--    to 'failed' instead of being retried past max_attempts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.requeue_stale_notification_queue(
  p_min_age_minutes INT DEFAULT 15
)
RETURNS TABLE (requeued INT, failed INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_requeued INT := 0;
  v_failed INT := 0;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF p_min_age_minutes IS NULL OR p_min_age_minutes < 1 THEN
    RAISE EXCEPTION 'p_min_age_minutes must be >= 1';
  END IF;

  WITH recovered AS (
    UPDATE public.notification_queue q
    SET status = CASE
          WHEN COALESCE(q.attempts, 0) >= COALESCE(q.max_attempts, 3)
            THEN 'failed'
          ELSE 'pending'
        END,
        failure_reason = COALESCE(
          q.failure_reason,
          'stale processing claim recovered'
        ),
        updated_at = now()
    WHERE q.status = 'processing'
      AND q.updated_at < now() - make_interval(mins => p_min_age_minutes)
    RETURNING q.status
  )
  SELECT
    COUNT(*) FILTER (WHERE status = 'pending')::int,
    COUNT(*) FILTER (WHERE status = 'failed')::int
  INTO v_requeued, v_failed
  FROM recovered;

  requeued := v_requeued;
  failed := v_failed;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.requeue_stale_notification_queue(INT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.requeue_stale_notification_queue(INT)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Harden the edge-invocation retention RPC.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cleanup_edge_function_invocations()
RETURNS TABLE (deleted_count INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted_count INT := 0;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  DELETE FROM public.edge_function_invocations
  WHERE invoked_at < now() - interval '7 days';

  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  deleted_count := v_deleted_count;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_edge_function_invocations()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_edge_function_invocations()
  TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Remove superseded pg_cron jobs. Each unschedule is conditional so the
--    migration is safe on a fresh database and on the live project alike.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_jobid BIGINT;
  v_job RECORD;
BEGIN
  IF to_regclass('cron.job') IS NULL THEN
    RETURN;
  END IF;

  -- delete-job-run-details (daily 12:00) duplicates the 30-day prune.
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'delete-job-run-details';
  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
    RAISE NOTICE 'unscheduled delete-job-run-details (duplicate cron-history prune)';
  END IF;

  -- The edge task now owns this prune and runs it once a day.
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'prune_edge_function_invocations';
  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
    RAISE NOTICE 'unscheduled prune_edge_function_invocations (moved to the cron-jobs task)';
  END IF;

  -- If both prune variants exist, keep only the runid-bounded replacement.
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'prune_cron_job_run_details';
  IF v_jobid IS NOT NULL
     AND EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'prune_cron_job_run_details_30d') THEN
    PERFORM cron.unschedule(v_jobid);
    RAISE NOTICE 'unscheduled prune_cron_job_run_details (replaced by prune_cron_job_run_details_30d)';
  END IF;

  -- Dashboard-created schedules that post to the same edge dispatcher are
  -- duplicate ticks. The migration-owned matchme-cron-jobs schedule is the
  -- only dispatcher that should remain.
  FOR v_job IN
    SELECT jobid, jobname
    FROM cron.job
    WHERE jobname <> 'matchme-cron-jobs'
      AND command ILIKE '%/functions/v1/cron-jobs%'
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
    RAISE NOTICE 'unscheduled duplicate cron-jobs dispatcher %', v_job.jobname;
  END LOOP;

  -- Direct-SQL pg_cron jobs that duplicate a task now owned by cron-jobs.
  -- These were created from the dashboard, not migrations, so they are matched
  -- by the function they call rather than by job name.
  FOR v_job IN
    SELECT jobid, jobname
    FROM cron.job
    WHERE command ILIKE ANY (ARRAY[
      '%cleanup_expired_matches%',
      '%cleanup_stale_online_users%',
      '%perform_continuous_event_matching%',
      '%perform_continuous_user_matching%',
      '%expire_pinned_locations%',
      '%touch_active_pinned_locations%',
      '%cleanup_old_user_locations%',
      '%cleanup_expired_offline_trail%',
      '%cleanup_orphan_profile_photos%',
      '%cleanup_stale_profile_photo_refs%',
      '%cleanup_orphan_sponsored_ad_images%',
      '%cleanup_expired_verification_photos%',
      '%cleanup_expired_email_codes%',
      '%cleanup_pending_email_changes%',
      '%cleanup_incomplete_signup_users%',
      '%cleanup_old_profile_edit_requests%',
      '%process_pending_referrals%',
      '%cleanup_edge_function_invocations%',
      '%queue_birthday_broadcast_notifications%',
      '%queue_profile_reminder_broadcast_notifications%',
      '%send_admin_broadcast%'
    ])
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
    RAISE NOTICE 'unscheduled duplicate SQL cron job %', v_job.jobname;
  END LOOP;
END $$;

COMMIT;
