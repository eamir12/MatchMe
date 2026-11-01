-- Migration: one-off prune of cron.job_run_details
-- Date: 2026-10-29
--
-- Why: the table holds 459,536 rows / 147 MB (122 MB heap) spanning 30 days.
-- 454,993 of those rows are older than 7 days; 380,313 belong to job 4, which
-- was retired on 2026-10-22 by the cron consolidation (migrations 2170-2181).
-- The two live jobs produce ~650 runs/day, so a 7-day window needs ~4.5k rows
-- (~2 MB). The scheduled job 7 keeps 30 days, so without this one-off the dead
-- history from job 4 would stay for another three weeks.
--
-- What: call the existing helper once with a 7-day retention. The helper is
-- SECURITY DEFINER, owned by postgres, search_path = pg_catalog, cron; it
-- deletes start_time < now() - p_retention and returns the row count. Calling
-- it again is safe (deletes ~0 rows).
-- Job 7 continues to prune at 30 days; changing that schedule requires the
-- Dashboard (Cron), because postgres has only SELECT on cron.job.
--
-- Blast radius: DELETE on cron.job_run_details only. No schema, job or
-- function change. The table has only the runid PK, so the delete is a seq
-- scan over 122 MB. autovacuum reclaims the dead tuples afterwards; the file
-- does not shrink (postgres is neither the table owner nor pg_maintain), but
-- the space is reused by later job runs.
--
-- Rollback: none needed. History rows are not read by the app; the data is
-- the same that job 7 would remove three weeks from now.
--
-- Verification: the DO block fails the migration if any row older than
-- 7 days survives.

set statement_timeout = '600s';
set lock_timeout = '5s';

select private.prune_cron_job_run_details(interval '7 days') as deleted_rows;

do $$
declare
  v_old bigint;
  v_remaining bigint;
begin
  select count(*) filter (where start_time < now() - interval '7 days'),
         count(*)
  into v_old, v_remaining
  from cron.job_run_details;

  if v_old > 0 then
    raise exception '% cron.job_run_details rows older than 7 days remain', v_old;
  end if;

  raise notice 'cron.job_run_details: % rows remain', v_remaining;
end $$;
