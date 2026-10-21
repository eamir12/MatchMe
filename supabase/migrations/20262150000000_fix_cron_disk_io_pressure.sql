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
--   12 statements accounted for 161,433 of 161,242 tracked read blocks
--   (100.1%). Every single one of them touches cron.job_run_details.
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
--     * the 30-day prune does a 274 MB seq scan (no index on start_time)
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
-- REVERSAL: every change here is a cron.schedule/cron.unschedule or a
-- CREATE INDEX; the previous cadence was '5 seconds' and the previous
-- job name was 'vacuum_cron_job_run_details'.

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
END $$;

-- ---------------------------------------------------------------------------
-- 3. Index the three access paths that currently seq-scan a 147 MB table.
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
--    CAVEAT: cron.job_run_details is owned by the pg_cron extension.
--    These indexes are safe (pg_cron only inserts/updates/deletes rows)
--    but they are NOT recreated automatically if pg_cron is reinstalled
--    or its table is rebuilt. This migration is the record of them --
--    re-apply it after any pg_cron upgrade.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS cron_job_run_details_start_time_idx
    ON cron.job_run_details (start_time);

CREATE INDEX IF NOT EXISTS cron_job_run_details_jobid_start_time_idx
    ON cron.job_run_details (jobid, start_time DESC);

CREATE INDEX IF NOT EXISTS cron_job_run_details_status_idx
    ON cron.job_run_details (status);

-- ---------------------------------------------------------------------------
-- 4. Verification (safe to read)
-- ---------------------------------------------------------------------------
SELECT jobid,
       jobname,
       schedule,
       active,
       left(regexp_replace(command, '\s+', ' ', 'g'), 80) AS command
FROM cron.job
ORDER BY jobid;

SELECT pg_size_pretty(pg_total_relation_size('cron.job_run_details')) AS total_size,
       (SELECT count(*) FROM cron.job_run_details)                     AS live_rows;

COMMIT;
