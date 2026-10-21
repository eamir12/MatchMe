-- =============================================================================
-- ONE single statement that confirms whether the cron disk-I/O migration
-- (20262150000000_fix_cron_disk_io_pressure.sql) ran successfully and
-- completely. No temp tables, no DO blocks, no second statement -- just
-- paste this and Run. The whole answer is one result set.
--
-- Run it ~24h after applying the migration so at least one 02:00 prune
-- cycle has passed.
-- =============================================================================
WITH
  idx AS (
    SELECT count(*) FILTER (WHERE indexname IN (
             'cron_job_run_details_start_time_idx',
             'cron_job_run_details_jobid_start_time_idx',
             'cron_job_run_details_status_idx'))::int AS new_idx_count,
           count(*)::int AS total_idx_count
    FROM pg_indexes
    WHERE schemaname = 'cron' AND tablename = 'job_run_details'),
  fns AS (
    SELECT count(*) FILTER (WHERE p.proname = 'prune_cron_job_run_details')::int AS prune_fn,
           count(*) FILTER (WHERE p.proname = 'cron_job_run_details_cutoff')::int AS cutoff_fn
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'),
  jobs AS (
    SELECT max(schedule)  FILTER (WHERE jobname = 'detect-offline-users')        AS offline_sched,
           max(command)   FILTER (WHERE jobname = 'detect-offline-users')        AS offline_cmd,
           count(*)       FILTER (WHERE jobname = 'vacuum_cron_job_run_details')::int AS vacuum_jobs,
           max(schedule)  FILTER (WHERE jobname = 'analyze_cron_job_run_details') AS analyze_sched,
           max(command)   FILTER (WHERE jobname = 'prune_cron_job_run_details_30d') AS prune_cmd
    FROM cron.job),
  own AS (
    SELECT pg_get_userbyid(c.relowner) AS owner,
           current_user AS running_as,
           pg_has_role(current_user, pg_get_userbyid(c.relowner), 'USAGE') AS can_assume
    FROM pg_class c WHERE c.oid = 'cron.job_run_details'::regclass),
  tbl AS (
    SELECT pg_size_pretty(pg_total_relation_size('cron.job_run_details')) AS size,
           (SELECT count(*) FROM cron.job_run_details)::bigint AS rows,
           (SELECT n_dead_tup::bigint FROM pg_stat_all_tables
             WHERE schemaname='cron' AND relname='job_run_details') AS dead,
           (SELECT autovacuum_count::bigint FROM pg_stat_all_tables
             WHERE schemaname='cron' AND relname='job_run_details') AS autovac_n),
  yday AS (
    SELECT count(*)::bigint AS runs
    FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid
    WHERE j.jobname = 'detect-offline-users'
      AND d.start_time >= date_trunc('day', now()) - interval '1 day'
      AND d.start_time <  date_trunc('day', now())),
  checks AS (
    SELECT 1 AS ord,
           '1. detect-offline-users cadence is 30 seconds (was 5 seconds)' AS check_name,
           CASE WHEN jobs.offline_sched = '30 seconds' THEN 'PASS' ELSE 'FAIL' END AS status,
           'schedule=' || coalesce(jobs.offline_sched, '<job missing>') ||
           ' cmd=' || left(coalesce(jobs.offline_cmd, '-'), 45) AS actual
    FROM jobs
    UNION ALL
    SELECT 2, 'nightly VACUUM job removed (replaced by ANALYZE)',
           CASE WHEN jobs.vacuum_jobs = 0 THEN 'PASS' ELSE 'FAIL' END,
           'vacuum_cron_job_run_details jobs found = ' || jobs.vacuum_jobs
    FROM jobs
    UNION ALL
    SELECT 3, 'nightly ANALYZE job installed at 02:10',
           CASE WHEN jobs.analyze_sched = '10 2 * * *' THEN 'PASS' ELSE 'FAIL' END,
           'schedule=' || coalesce(jobs.analyze_sched, '<job missing>')
    FROM jobs
    UNION ALL
    SELECT 4, 'prune job uses an index-friendly path',
           CASE WHEN idx.new_idx_count = 3
                     OR jobs.prune_cmd LIKE '%private.prune_cron_job_run_details%'
                THEN 'PASS' ELSE 'FAIL' END,
           'new indexes=' || idx.new_idx_count || '/' || idx.total_idx_count ||
           ' prune_cmd=' || left(coalesce(jobs.prune_cmd, '<job missing>'), 52)
    FROM jobs, idx
    UNION ALL
    SELECT 5, 'private.prune_cron_job_run_details() installed',
           CASE WHEN fns.prune_fn = 1 THEN 'PASS' ELSE 'FAIL' END,
           'found=' || fns.prune_fn FROM fns
    UNION ALL
    SELECT 6, 'private.cron_job_run_details_cutoff() installed',
           CASE WHEN fns.cutoff_fn = 1 THEN 'PASS' ELSE 'FAIL' END,
           'found=' || fns.cutoff_fn FROM fns
    UNION ALL
    SELECT 7,            '7. cron jobs are actually running (no failed runs)',
           CASE WHEN (SELECT count(*) FROM (
                      SELECT j.jobname
                      FROM cron.job j
                      JOIN LATERAL (SELECT status FROM cron.job_run_details
                                     WHERE jobid = j.jobid
                                     ORDER BY start_time DESC LIMIT 1) d ON true
                      WHERE d.status <> 'succeeded') x) = 0
                THEN 'PASS' ELSE 'FAIL' END,
           (SELECT string_agg(jobname || '=' || status, ', ')
            FROM (SELECT j.jobname, d.status
                  FROM cron.job j
                  JOIN LATERAL (SELECT status FROM cron.job_run_details
                                 WHERE jobid = j.jobid
                                 ORDER BY start_time DESC LIMIT 1) d ON true) y)
  )
SELECT z.section, z.item, z.value, z.detail
FROM (
SELECT 'CHECK' AS section,
       c.check_name AS item,
       c.status AS value,
       c.actual AS detail
FROM checks c

UNION ALL
SELECT 'MEASURE', 'detect-offline-users runs yesterday (target ~2,880, was ~17,000)',
       (SELECT runs::text FROM yday), 'runs in the last full day'
UNION ALL
SELECT 'MEASURE', 'cron.job_run_details size / rows',
       (SELECT size || ' / ' || rows::text FROM tbl),
       'was 147 MB / 603,511 rows -- shrinks ~19,300/day for ~30 days'
UNION ALL
SELECT 'MEASURE', 'dead tuples / autovacuum count',
       (SELECT dead::text || ' / ' || autovac_n::text FROM tbl),
       'autovacuum_count was 0 before (the nightly vacuum masked it)'
UNION ALL
SELECT 'MEASURE', 'indexes on cron.job_run_details',
       (SELECT new_idx_count::text || ' of 3 new (plus ' || total_idx_count::text || ' total)'
        FROM idx),
       'ownership: owner=' || (SELECT owner FROM own) ||
       ' running_as=' || (SELECT running_as FROM own) ||
       ' can_assume=' || (SELECT can_assume::text FROM own)
UNION ALL
SELECT 'MEASURE', 'vacuum-context reads (the thing we wanted to kill)',
       (SELECT coalesce(sum(reads)::text, '0') FROM pg_stat_io
        WHERE context = 'vacuum' AND object = 'relation'),
       'baseline was 53,990 reads (422 MB) across the window'
UNION ALL
SELECT 'MEASURE', 'bulkread-context reads (sequential scans)',
       (SELECT coalesce(sum(reads)::text, '0') FROM pg_stat_io
        WHERE context = 'bulkread'),
       'baseline was 81,649 reads (638 MB)'
UNION ALL
SELECT 'MEASURE', 'wal_mb_per_day',
       (SELECT round((wal_bytes::numeric
             / NULLIF(EXTRACT(EPOCH FROM (now() - (SELECT stats_reset FROM pg_stat_wal)))
                      / 86400.0, 0)) / 1048576.0, 2)::text FROM pg_stat_wal),
       'baseline was 84.03 MB/day'
UNION ALL
SELECT 'VERDICT', 'migration status',
       CASE WHEN (SELECT count(*) FROM checks WHERE status = 'FAIL') = 0
            THEN 'COMPLETE' ELSE 'INCOMPLETE' END,
       (SELECT count(*) FROM checks WHERE status = 'PASS')::text || ' passed, ' ||
       (SELECT count(*) FROM checks WHERE status = 'FAIL')::text || ' failed' ||
       ' | ' || coalesce((SELECT string_agg(check_name, '; ') FROM checks WHERE status = 'FAIL'),
                        'no failed checks')
) z
ORDER BY CASE z.section WHEN 'CHECK' THEN 1 WHEN 'MEASURE' THEN 2 ELSE 3 END, z.item;
