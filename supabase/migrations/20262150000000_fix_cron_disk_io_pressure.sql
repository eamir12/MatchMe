-- Migration: cut the cron-history disk I/O that the pg_stat_statements
--             analysis blamed on the wrong thing.
--
-- MEASURED (Supabase Cloud, PG 17.11, pg_stat_statements window
-- 2026-10-17 19:21 UTC -> 2026-10-21 09:48 UTC, ~3.6 days):
--
--   pg_stat_io (aligned window, since last crash-recovery reset):
--     client backend | relation | bulkread    59,098 reads = 462 MB   42%
--     client backend | relation | vacuum      53,990 reads = 422 MB   38%
--     background worker | relation | bulkread 22,551 reads = 176 MB   16%
--     client backend | relation | normal       5,171 reads =  40 MB    4%
--     autovacuum (both contexts)                 504 reads =   4 MB   0.4%
--
--   12 statements accounted for 158,433 of 161,242 tracked read blocks
--   (98.3%). Every single one of them touches cron.job_run_details.
--   So the original analysis was RIGHT that the cron history dominates
--   reads -- but its FIXES (shorter retention, an index) treat the
--   symptom, not the cause.
--
-- ROOT CAUSE FOUND HERE:
--
--   The 'detect-offline-users' job runs on a '5 seconds' schedule and
--   writes ~17,000 rows/day into cron.job_run_details:
--       2026-10-18  16,962 runs
--       2026-10-19  17,006 runs
--       2026-10-20  16,770 runs
--   (69,284 INSERTs into cron.job_run_details over the 3.6-day window,
--   plus ~85,000 UPDATEs from pg_cron's own per-run bookkeeping.)
--
--   The table holds 603,511 rows / 147 MB. 85% of those rows come from
--   that one 5-second job. Everything downstream follows from it:
--     * the 30-day prune does a 274 MB seq scan
--     * the nightly VACUUM does a 422 MB full-heap scan
--     * ~85,000 UPDATEs/day dirty pages that the checkpointer writes
--       back (1,017 MB of checkpoint writeback, of which pg_stat_
--       statements explains only 3%)
--
-- WHY A 5-SECOND SWEEP IS POINTLESS HERE:
--
--   * the client heartbeat runs every 30 s
--     (lib/services/user_activity_service.dart:20 -- _heartbeatInterval)
--   * public.is_user_online() treats a user as online for 2 minutes
--     (20260414000003_increase_is_user_online_window.sql)
--
--   A sweep every 5 s is 6x more frequent than the heartbeat and can
--   only ever act on state that is already 2 minutes stale. Dropping to
--   30 s preserves the semantics (worst-case offline-marking delay
--   moves from 5 s to 30 s, against a 120 s staleness window) and
--   removes ~75% of the rows in the table.
--
-- WHY THE NIGHTLY VACUUM GOES AWAY:
--
--   vacuum (analyze) cron.job_run_details:
--       4 calls, 53,990 blocks read (422 MB), 723 blocks written (5.6 MB)
--   A 1.3% write ratio means it reclaims essentially nothing -- it
--   scans the whole heap to find no dead tuples. It also keeps
--   autovacuum permanently disabled on this table (autovacuum_count = 0,
--   last_autovacuum = never), because it reclaims the ~19K dead tuples
--   the prune creates every day before autovacuum's threshold
--   (50 + 0.2 * 597,382 = 119,526) is ever reached.
--
--   Removing the nightly vacuum lets autovacuum do the job in one pass
--   every ~6 days instead of one full scan every single night. The
--   ANALYZE is kept -- but as a standalone ANALYZE, which samples
--   30,000 rows (~300 pages) instead of scanning all 15,600 pages.
--
-- REVERSAL: every change here is a cron.schedule/cron.unschedule, a
-- CREATE INDEX, or a CREATE FUNCTION. The previous cadence was
-- '5 seconds', the previous job name was 'vacuum_cron_job_run_details',
-- and the previous prune command was:
--   delete from cron.job_run_details where start_time < now() - interval '30 days'

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. detect-offline-users: 5 seconds -> 30 seconds.
--    The command is read back from cron.job so we re-register exactly
--    what is live, not a copy that could drift.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_cmd text;
BEGIN
  SELECT command INTO v_cmd FROM cron.job WHERE jobname = 'detect-offline-users';
  IF v_cmd IS NULL THEN
    RAISE NOTICE 'detect-offline-users not found - left untouched';
    RETURN;
  END IF;

  PERFORM cron.schedule('detect-offline-users', '30 seconds', v_cmd);
  RAISE NOTICE 'detect-offline-users rescheduled 5 seconds -> 30 seconds';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'could not reschedule detect-offline-users: %', SQLERRM;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Replace the nightly full-table VACUUM with a standalone ANALYZE.
--    Same schedule slot (02:10), ~50x cheaper, and it lets autovacuum
--    reclaim the prune's dead tuples on its own schedule.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_cmd text;
BEGIN
  SELECT command INTO v_cmd FROM cron.job WHERE jobname = 'vacuum_cron_job_run_details';
  IF v_cmd IS NOT NULL THEN
    PERFORM cron.unschedule('vacuum_cron_job_run_details');
    RAISE NOTICE 'unscheduled vacuum_cron_job_run_details';
  END IF;

  PERFORM cron.schedule('analyze_cron_job_run_details', '10 2 * * *',
                        'ANALYZE cron.job_run_details;');
  RAISE NOTICE 'scheduled analyze_cron_job_run_details at 02:10 daily';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'could not replace the nightly vacuum: %', SQLERRM;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Index the access paths that currently seq-scan a 147 MB table.
--
--    (a) start_time -- the 30-day prune:
--          delete from cron.job_run_details
--           where start_time < now() - interval '30 days'
--        4 calls, 35,014 blocks = 274 MB, 82,306 rows deleted.
--
--    (b) jobid, start_time DESC -- "recent runs for this job", which is
--        what the repo's own diagnostics query
--        (.tmp/profile_reminder_readonly_diagnostic.sql:143):
--          SELECT status, return_message, start_time, end_time
--          FROM cron.job_run_details
--          WHERE jobid = (...) ORDER BY start_time DESC LIMIT 15
--        2 calls, 20,635 blocks = 161 MB for 20 rows.
--
--    (c) status -- the one-off "mark still-running jobs as failed":
--          update cron.job_run_details
--             set status = $1, return_message = $2
--           where status in ($3, $4)
--        1 call, 15,591 blocks = 122 MB to update 0 rows.
--
--    OWNERSHIP: cron.job_run_details belongs to the pg_cron extension
--    owner (supabase_admin on Supabase Cloud), and PostgreSQL refuses
--    CREATE INDEX on a table you do not own:
--        ERROR: 42501: must be owner of table job_run_details
--    pg_cron grants SELECT/INSERT/UPDATE/DELETE on that table to the
--    role that owns the jobs, but not ownership -- so the index cannot
--    be created by the migration role.
--
--    This block therefore:
--      1. finds the real owner,
--      2. tries to assume that role (SET LOCAL ROLE) -- it works if the
--         migration role is a member of it,
--      3. creates the indexes, tolerating individual failures,
--      4. and NEVER aborts the migration.
--    Step 4 matters: the cron changes above are the high-value part;
--    losing them because an index is unavailable would be the wrong
--    trade. Section 4 covers the case where the index is refused.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_owner    text;
  v_stmts    text[] := ARRAY[
    'CREATE INDEX IF NOT EXISTS cron_job_run_details_start_time_idx
       ON cron.job_run_details (start_time)',
    'CREATE INDEX IF NOT EXISTS cron_job_run_details_jobid_start_time_idx
       ON cron.job_run_details (jobid, start_time DESC)',
    'CREATE INDEX IF NOT EXISTS cron_job_run_details_status_idx
       ON cron.job_run_details (status)'];
  v_stmt     text;
  v_created  int := 0;
  v_switched boolean := false;
BEGIN
  BEGIN
    SELECT pg_get_userbyid(c.relowner) INTO v_owner
    FROM pg_class c
    WHERE c.oid = 'cron.job_run_details'::regclass;

    BEGIN
      EXECUTE format('SET LOCAL ROLE %I', v_owner);
      v_switched := true;
      RAISE NOTICE 'cron.job_run_details is owned by %; assumed that role', v_owner;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'cron.job_run_details is owned by % but this role cannot assume it: %',
                   v_owner, SQLERRM;
    END;

    FOREACH v_stmt IN ARRAY v_stmts LOOP
      BEGIN
        EXECUTE v_stmt;
        v_created := v_created + 1;
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'index not created: %', SQLERRM;
      END;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'index block failed (non-fatal): %', SQLERRM;
  END;

  IF v_switched THEN
    BEGIN EXECUTE 'RESET ROLE'; EXCEPTION WHEN OTHERS THEN NULL; END;
  END IF;

  IF v_created < 3 THEN
    RAISE NOTICE 'only % of 3 indexes created - falling back to the runid-bounded prune (section 4)', v_created;
  ELSE
    RAISE NOTICE 'all 3 indexes created';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Fallback when the index is refused: a runid-bounded prune.
--
--    cron.job_run_details already has its PRIMARY KEY on runid, and runid
--    is a bigserial, so runid order matches start_time order. That makes
--    it possible to find "the oldest runid to keep" with a binary search
--    over the PK -- ~20 index lookups -- instead of scanning the whole
--    heap for every row older than the cutoff.
--
--    IMPORTANT: the DELETE must live INSIDE the function. Written as
--        DELETE ... WHERE runid < private.cron_job_run_details_cutoff(...)
--    the planner cannot use the index (the bound is a function call, not
--    a constant it can fold at plan time) and falls back to a seq scan.
--    Inside plpgsql the boundary is a bind parameter, so the planner
--    does choose an index scan:
--        Delete on job_run_details
--          -> Index Scan using job_run_details_pkey on job_run_details
--             Index Cond: (runid < $1)
--
--    Because the doomed rows are the OLDEST rows, they sit at the front
--    of an append-only heap, so the heap visits touch only the first few
--    percent of the table. Prune cost becomes proportional to the rows
--    deleted, not to the table size.
--
--    Correctness: the boundary search only ever moves FORWARD after the
--    binary search, so it can prune slightly less than the exact
--    cutoff, never more. A 30-day retention policy tolerates that by
--    seconds.
--
--    Privileges: pg_cron grants SELECT/INSERT/UPDATE/DELETE on
--    cron.job_run_details to the role that owns the jobs (that is how
--    the existing prune job deletes 82,306 rows). This function needs
--    only those -- no ownership of the extension's table.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_has_idx boolean := false;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'cron' AND tablename = 'job_run_details'
      AND indexname = 'cron_job_run_details_start_time_idx'
  ) INTO v_has_idx;

  IF v_has_idx THEN
    RAISE NOTICE 'start_time index present - keeping the existing prune command';
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'private') THEN
    BEGIN
      CREATE SCHEMA private;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'could not create schema private: %', SQLERRM;
    END;
  END IF;

  BEGIN
    -- read-only helper: the first runid that must be KEPT
    EXECUTE $fn$
      CREATE OR REPLACE FUNCTION private.cron_job_run_details_cutoff(
          p_retention interval DEFAULT '30 days')
      RETURNS bigint
      LANGUAGE plpgsql
      STABLE
      SET search_path = pg_catalog, cron
      AS $body$
      DECLARE
        v_lo     bigint;
        v_hi     bigint;
        v_mid    bigint;
        v_st     timestamptz;
        v_cutoff timestamptz := now() - p_retention;
        v_steps  int := 0;
      BEGIN
        SELECT min(runid), max(runid) INTO v_lo, v_hi FROM cron.job_run_details;
        IF v_lo IS NULL THEN
          RETURN NULL;
        END IF;

        -- binary search for the first runid whose start_time >= cutoff
        WHILE v_lo <= v_hi AND v_steps < 64 LOOP
          v_steps := v_steps + 1;
          v_mid := v_lo + (v_hi - v_lo) / 2;

          SELECT start_time INTO v_st
          FROM cron.job_run_details WHERE runid = v_mid;

          IF v_st IS NULL THEN
            v_hi := v_mid - 1;
          ELSIF v_st < v_cutoff THEN
            v_lo := v_mid + 1;
          ELSE
            v_hi := v_mid - 1;
          END IF;
        END LOOP;

        -- safety: never keep a boundary that is itself older than the cutoff
        LOOP
          SELECT start_time INTO v_st
          FROM cron.job_run_details WHERE runid = v_lo;
          EXIT WHEN v_st IS NULL OR v_st >= v_cutoff OR v_steps > 256;
          v_steps := v_steps + 1;
          v_lo := v_lo + 1;
        END LOOP;

        RETURN v_lo;
      END;
      $body$
    $fn$;

    -- the prune itself: boundary is a bind parameter, so the planner
    -- uses the primary key instead of scanning the heap
    EXECUTE $fn$
      CREATE OR REPLACE FUNCTION private.prune_cron_job_run_details(
          p_retention interval DEFAULT '30 days')
      RETURNS bigint
      LANGUAGE plpgsql
      VOLATILE
      SECURITY DEFINER
      SET search_path = pg_catalog, cron
      AS $body$
      DECLARE
        v_cutoff_runid bigint;
        v_deleted      bigint := 0;
      BEGIN
        v_cutoff_runid := private.cron_job_run_details_cutoff(p_retention);
        IF v_cutoff_runid IS NULL THEN
          RETURN 0;
        END IF;

        DELETE FROM cron.job_run_details WHERE runid < v_cutoff_runid;
        GET DIAGNOSTICS v_deleted = ROW_COUNT;
        RETURN v_deleted;
      END;
      $body$
    $fn$;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'could not create the runid-bounded prune functions: %', SQLERRM;
    RETURN;
  END;

  BEGIN
    PERFORM cron.schedule(
      'prune_cron_job_run_details_30d',
      '0 2 * * *',
      'SELECT private.prune_cron_job_run_details(interval ''30 days'');');
    RAISE NOTICE 'prune job re-pointed at the runid-bounded delete';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'could not re-point the prune job: %', SQLERRM;
  END;
END $$;

-- ---------------------------------------------------------------------------
-- 5. Verification (safe to read)
-- ---------------------------------------------------------------------------
SELECT jobid,
       jobname,
       schedule,
       active,
       left(regexp_replace(command, '\s+', ' ', 'g'), 90) AS command
FROM cron.job
ORDER BY jobid;

-- Ownership diagnostic: who owns the extension table, and can this role
-- assume that role? (If can_assume_owner is false, the index must be
-- created by the table owner or by Supabase support.)
SELECT pg_get_userbyid(c.relowner)                          AS table_owner,
       current_user                                          AS running_as,
       pg_has_role(current_user, pg_get_userbyid(c.relowner), 'USAGE')
                                                             AS can_assume_owner
FROM pg_class c
WHERE c.oid = 'cron.job_run_details'::regclass;

SELECT indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'cron' AND tablename = 'job_run_details'
ORDER BY indexname;

COMMIT;
