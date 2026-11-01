-- Fold the last standalone cron schedules into the cron-jobs dispatcher.
--
-- 20262179000000 removed every job that duplicated a function the dispatcher
-- already owned. The dashboard still showed:
--
--   subscription-normalization         business logic (expiry downgrade)
--   delete-expired-location-signals    retention / privacy
--   check-due-rating-prompts           proactive rating prompts
--   cleanup-expired-meetups            meetup expiry + spot-card purge
--   prune_edge_function_invocations    superseded by the daily edge task, but
--                                      its command is a raw DELETE so the 2179
--                                      function-name match did not catch it
--   analyze_cron_job_run_details       optional; autovacuum covers the table
--   prune_cron_job_run_details_30d     keep - it must run as the cron owner
--
-- The four application jobs move into cron-jobs (cadence-gated there):
--   5 min: subscription normalization, location signals, rating prompts
--  10 min: meetup cleanup

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) RPC surface for the moved tasks.
--    The location cleanup previously returned void, so it is recreated with a
--    deleted count and a service-role guard; nothing else calls it.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.cleanup_expired_location_share_signals();

CREATE FUNCTION public.cleanup_expired_location_share_signals()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted integer;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  DELETE FROM public.location_share_signals
  WHERE expires_at IS NOT NULL AND expires_at < now();

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_expired_location_share_signals()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_location_share_signals()
  TO service_role;

REVOKE ALL ON FUNCTION public.cleanup_expired_meetups()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_meetups()
  TO service_role;

GRANT EXECUTE ON FUNCTION public.check_all_due_rating_prompts()
  TO service_role;
GRANT EXECUTE ON FUNCTION public.scheduled_subscription_normalization()
  TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Remove the four moved schedules and the two obsolete ones.
--    Matched by name and by command so dashboard-created duplicates are caught.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_job RECORD;
BEGIN
  IF to_regclass('cron.job') IS NULL THEN
    RETURN;
  END IF;

  FOR v_job IN
    SELECT jobid, jobname
    FROM cron.job
    WHERE jobname <> 'matchme-cron-jobs'
      AND (
        jobname IN (
          'subscription-normalization',
          'delete-expired-location-signals',
          'check-due-rating-prompts',
          'cleanup-expired-meetups',
          'analyze_cron_job_run_details'
        )
        OR jobname LIKE 'prune_edge_function_invocations%'
        OR jobname LIKE 'delete-job-run-details%'
        OR command ILIKE '%scheduled_subscription_normalization%'
        OR command ILIKE '%location_share_signals%'
        OR command ILIKE '%check_all_due_rating_prompts%'
        OR command ILIKE '%cleanup_expired_meetups%'
        OR command ILIKE '%public.edge_function_invocations%'
      )
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
    RAISE NOTICE 'unscheduled % (moved to cron-jobs or obsolete)', v_job.jobname;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3) Keep the cron-history prune active. It stays a SQL job because it deletes
--    from cron.job_run_details, owned by the pg_cron extension.
--    Recreate instead of alter when the job is missing or deactivated.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_jobid bigint;
BEGIN
  IF to_regclass('cron.job') IS NULL
     OR to_regprocedure('private.prune_cron_job_run_details(interval)') IS NULL THEN
    RETURN;
  END IF;

  SELECT jobid INTO v_jobid
  FROM cron.job
  WHERE jobname = 'prune_cron_job_run_details_30d';

  IF v_jobid IS NULL THEN
    BEGIN
      PERFORM cron.schedule(
        'prune_cron_job_run_details_30d',
        '0 2 * * *',
        'SELECT private.prune_cron_job_run_details(interval ''30 days'');'
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'could not recreate prune_cron_job_run_details_30d: %', SQLERRM;
    END;
    RETURN;
  END IF;

  BEGIN
    PERFORM cron.alter_job(v_jobid, active => true);
  EXCEPTION WHEN OTHERS THEN
    -- Older pg_cron without alter_job(active): recreate the job active.
    BEGIN
      PERFORM cron.unschedule(v_jobid);
      PERFORM cron.schedule(
        'prune_cron_job_run_details_30d',
        '0 2 * * *',
        'SELECT private.prune_cron_job_run_details(interval ''30 days'');'
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'could not re-activate prune_cron_job_run_details_30d: %', SQLERRM;
    END;
  END;
END $$;

COMMIT;
