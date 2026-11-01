-- Replace the runid-binary-search prune with an exact delete by start_time.
--
-- 20262150000000's fallback found a "first runid to keep" by binary search
-- under the assumption that runid order matches start_time order and that
-- every row has a start_time. Neither holds in practice: pg_cron leaves
-- 'connecting' rows with NULL start_time behind, and runids do not stay
-- time-ordered across partial prunes/restores. On the live table the
-- computed cutoff landed at min(runid), so the function deleted 0 rows while
-- ~100k rows older than 31 days stayed behind -- and the cron job still
-- reported success (return_message 0).
--
-- A delete on start_time is exact regardless of runid order. Cost: one
-- sequential scan per run over a table already pruned to ~30 days, once a
-- day at 02:00.

BEGIN;

CREATE OR REPLACE FUNCTION private.prune_cron_job_run_details(
    p_retention interval DEFAULT '30 days')
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, cron
AS $$
DECLARE
  v_deleted bigint := 0;
BEGIN
  IF p_retention IS NULL OR p_retention <= interval '0' THEN
    RAISE EXCEPTION 'retention must be positive';
  END IF;

  DELETE FROM cron.job_run_details
  WHERE start_time < now() - p_retention;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

-- The cutoff helper existed only for the binary search.
DO $$
BEGIN
  IF to_regprocedure('private.cron_job_run_details_cutoff(interval)') IS NOT NULL THEN
    DROP FUNCTION private.cron_job_run_details_cutoff(interval);
  END IF;
END $$;

-- Re-assert the job so it is active and points at the function even if an
-- earlier migration left the old direct-DELETE command in place.
DO $$
DECLARE
  v_jobid bigint;
  v_cmd   text := 'SELECT private.prune_cron_job_run_details(interval ''30 days'');';
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
      PERFORM cron.schedule('prune_cron_job_run_details_30d', '0 2 * * *', v_cmd);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'could not create prune job: %', SQLERRM;
    END;
    RETURN;
  END IF;

  BEGIN
    PERFORM cron.alter_job(v_jobid, command => v_cmd, active => true);
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      PERFORM cron.unschedule(v_jobid);
      PERFORM cron.schedule('prune_cron_job_run_details_30d', '0 2 * * *', v_cmd);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'could not re-point/re-activate prune job: %', SQLERRM;
    END;
  END;
END $$;

COMMIT;
