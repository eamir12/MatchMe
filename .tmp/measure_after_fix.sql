-- =============================================================================
-- Post-fix measurement: one statement, one result set.
-- Answers: did the cadence change actually take effect, do the jobs complete,
-- and is the prune deleting rows?
-- Run it at least 1 hour after the migration.
-- =============================================================================
WITH
  off AS (
    SELECT j.jobid FROM cron.job j WHERE j.jobname = 'detect-offline-users'),
  hourly AS (
    SELECT date_trunc('hour', d.start_time) AS hr,
           count(*)::bigint AS runs,
           count(*) FILTER (WHERE d.status = 'succeeded')::bigint AS ok,
           count(*) FILTER (WHERE d.status IN ('connecting','running'))::bigint AS inflight,
           count(*) FILTER (WHERE d.status = 'failed')::bigint AS failed
    FROM cron.job_run_details d
    WHERE d.jobid IN (SELECT jobid FROM off)
      AND d.start_time > now() - interval '8 hours'
    GROUP BY 1),
  dur AS (
    SELECT count(*)::bigint AS runs,
           round(avg(EXTRACT(EPOCH FROM (d.end_time - d.start_time)))::numeric, 2) AS avg_sec,
           round(max(EXTRACT(EPOCH FROM (d.end_time - d.start_time)))::numeric, 2) AS max_sec,
           round(percentile_cont(0.95) WITHIN GROUP
                 (ORDER BY EXTRACT(EPOCH FROM (d.end_time - d.start_time)))::numeric, 2) AS p95_sec,
           count(*) FILTER (WHERE d.status IN ('connecting','running'))::bigint AS stuck,
           count(*) FILTER (WHERE d.status = 'failed')::bigint AS failed
    FROM cron.job_run_details d
    WHERE d.jobid IN (SELECT jobid FROM off)
      AND d.start_time > now() - interval '8 hours'),
  prune AS (
    SELECT d.start_time, d.end_time, d.status, d.return_message,
           EXTRACT(EPOCH FROM (d.end_time - d.start_time)) AS secs
    FROM cron.job_run_details d
    WHERE d.jobid IN (SELECT jobid FROM cron.job WHERE jobname = 'prune_cron_job_run_details_30d')
      AND d.start_time > now() - interval '3 days'
    ORDER BY d.start_time DESC LIMIT 4)

SELECT 'A_hourly_runs' AS section,
       z.item, z.value, z.detail
FROM (SELECT 'detect-offline-users @ ' || hr::text AS item,
             runs::text || ' runs (' || ok::text || ' ok)' AS value,
             'inflight=' || inflight::text || ' failed=' || failed::text ||
             ' | 720/hr = old 5s cadence, 120/hr = new 30s cadence' AS detail
      FROM hourly ORDER BY hr) z

UNION ALL
SELECT 'B_run_durations',
       'last 8 hours',
       'avg=' || avg_sec::text || 's p95=' || p95_sec::text || 's max=' || max_sec::text || 's',
       'runs=' || runs::text || ' stuck_in_connecting_or_running=' || stuck::text ||
       ' failed=' || failed::text ||
       ' | if max > 30s the job overruns its own interval'
FROM dur

UNION ALL
SELECT 'C_prune_job',
       'prune run @ ' || start_time::text,
       status || ' in ' || round(secs::numeric, 1)::text || 's',
       coalesce(return_message, '')
FROM prune

UNION ALL
SELECT 'D_rows_per_day', z.item, z.value, z.detail
FROM (SELECT 'detect-offline-users @ ' || d::text AS item,
             runs::text AS value,
             'old rate was 16,962-17,006/day; new rate should be ~2,880/day' AS detail
      FROM (SELECT date_trunc('day', start_time)::date AS d, count(*)::bigint AS runs
            FROM cron.job_run_details
            WHERE jobid IN (SELECT jobid FROM off)
              AND start_time > now() - interval '4 days'
            GROUP BY 1) x
      ORDER BY 1) z

UNION ALL
SELECT 'E_table',
       'size / rows',
       pg_size_pretty(pg_total_relation_size('cron.job_run_details')) || ' / ' ||
       (SELECT count(*) FROM cron.job_run_details)::text,
       'was 147 MB / 603,511 rows; loses ~19,300/day for ~30 days'
UNION ALL
SELECT 'F_indexes',
       'indexes on cron.job_run_details',
       (SELECT count(*)::text || ' total (' ||
        count(*) FILTER (WHERE indexname LIKE 'cron_job_run_details%')::text || ' from this fix)'
        FROM pg_indexes WHERE schemaname='cron' AND tablename='job_run_details'),
       'owner=' || (SELECT pg_get_userbyid(c.relowner) FROM pg_class c
                    WHERE c.oid='cron.job_run_details'::regclass) ||
       ' running_as=' || current_user ||
       ' can_assume=' || (SELECT pg_has_role(current_user, pg_get_userbyid(c.relowner),'USAGE')::text
                          FROM pg_class c WHERE c.oid='cron.job_run_details'::regclass)
