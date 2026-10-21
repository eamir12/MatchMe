-- =============================================================================
-- Run this on 2026-10-22 AFTER 02:11 UTC. It verifies the two jobs that the
-- migration created/changed, neither of which has executed yet:
--   * prune_cron_job_run_details_30d @ 02:00  (now runs the runid-bounded
--     function instead of a full seq scan)
--   * analyze_cron_job_run_details   @ 02:10  (replaces the nightly VACUUM)
-- One statement, one result set.
-- =============================================================================
WITH prune_runs AS (
  SELECT d.start_time, d.end_time, d.status, d.return_message,
         EXTRACT(EPOCH FROM (d.end_time - d.start_time)) AS secs
  FROM cron.job_run_details d
  JOIN cron.job j ON j.jobid = d.jobid
  WHERE j.jobname = 'prune_cron_job_run_details_30d'
    AND d.start_time > now() - interval '2 days'
  ORDER BY d.start_time DESC NULLS LAST LIMIT 3),
analyze_runs AS (
  SELECT d.start_time, d.end_time, d.status, d.return_message,
         EXTRACT(EPOCH FROM (d.end_time - d.start_time)) AS secs
  FROM cron.job_run_details d
  JOIN cron.job j ON j.jobid = d.jobid
  WHERE j.jobname = 'analyze_cron_job_run_details'
    AND d.start_time > now() - interval '2 days'
  ORDER BY d.start_time DESC NULLS LAST LIMIT 3),
off_hours AS (
  SELECT date_trunc('day', d.start_time)::date AS d, count(*)::bigint AS runs
  FROM cron.job_run_details d
  JOIN cron.job j ON j.jobid = d.jobid
  WHERE j.jobname = 'detect-offline-users'
    AND d.start_time > (current_date - 2)
  GROUP BY 1)
SELECT 'A_prune_runs' AS section,
       z.start_time::text AS item,
       z.status || ' in ' || round(z.secs::numeric, 1)::text || 's' AS value,
       'return_message=' || coalesce(z.return_message, '') ||
       '  <- expect a BARE number like 20574 (old command said "DELETE 20574")' AS detail
FROM prune_runs z

UNION ALL
SELECT 'B_analyze_runs', z.start_time::text,
       z.status || ' in ' || round(z.secs::numeric, 1)::text || 's',
       'return_message=' || coalesce(z.return_message, '')
FROM analyze_runs z

UNION ALL
SELECT 'C_detect_offline_runs_per_day', z.d::text,
       z.runs::text,
       'old rate 16,962-17,006/day; new rate should be ~1,440/day (30s cadence)'
FROM off_hours z

UNION ALL
SELECT 'D_table', 'size / rows',
       pg_size_pretty(pg_total_relation_size('cron.job_run_details')) || ' / ' ||
       (SELECT count(*) FROM cron.job_run_details)::text,
       'was 147 MB / 604,072 rows on 2026-10-21; sheds ~15,400/day for ~30 days'
UNION ALL
SELECT 'E_vacuum_reads', 'vacuum-context reads since last reset',
       (SELECT coalesce(sum(reads)::text, '0') FROM pg_stat_io
        WHERE context = 'vacuum' AND object = 'relation'),
       'should stop growing now the nightly VACUUM is gone (it was 54,413)'
UNION ALL
SELECT 'F_stuck_rows', 'rows with status=connecting and NULL start_time',
       (SELECT count(*)::text FROM cron.job_run_details
        WHERE status = 'connecting' AND start_time IS NULL),
       'pg_cron inserts these before it sets start_time; a few are left behind. Harmless.'
