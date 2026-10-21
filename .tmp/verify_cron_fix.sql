-- =============================================================================
-- ONE consolidated verification of the cron disk-I/O fix.
-- The Supabase SQL Editor only surfaces the LAST result set, so this is a
-- single UNION ALL: one result set, one thing to paste back.
-- Run it ~24h after the migration so at least one prune cycle has passed.
-- =============================================================================
WITH
  meta AS (
    SELECT now() AS checked_at,
           (SELECT stats_reset FROM pg_stat_wal) AS wal_stats_reset),
  job_runs AS (
    SELECT j.jobid,
           COALESCE(to_jsonb(j)->>'jobname', '(unnamed)') AS jobname,
           d.day,
           d.runs
    FROM cron.job j
    JOIN (SELECT jobid, date_trunc('day', start_time)::date AS day, count(*) AS runs
          FROM cron.job_run_details
          WHERE start_time > now() - interval '3 days'
          GROUP BY 1, 2) d ON d.jobid = j.jobid)

SELECT 'A_jobs' AS section, z.item, z.value, z.detail
FROM (SELECT jobname AS item,
             schedule AS value,
             left(regexp_replace(command, '\s+', ' ', 'g'), 95) AS detail
      FROM cron.job
      WHERE jobid IN (SELECT DISTINCT jobid FROM job_runs)
         OR jobname IN ('detect-offline-users', 'analyze_cron_job_run_details',
                        'vacuum_cron_job_run_details', 'prune_cron_job_run_details_30d')
      ORDER BY 1) z

UNION ALL
SELECT 'A2_last_run', z.jobname, z.status, z.detail
FROM (SELECT j.jobname,
             d.status,
             coalesce(d.return_message, '') || ' @ ' || d.start_time::text AS detail
      FROM cron.job j
      JOIN LATERAL (SELECT status, return_message, start_time
                     FROM cron.job_run_details
                     WHERE jobid = j.jobid
                     ORDER BY start_time DESC LIMIT 1) d ON true
      ORDER BY 1) z

UNION ALL
SELECT 'B_history_table',
       'size / rows',
       pg_size_pretty(pg_total_relation_size('cron.job_run_details')) || ' / ' ||
       (SELECT count(*) FROM cron.job_run_details)::text,
       'oldest=' || (SELECT min(start_time)::text FROM cron.job_run_details) ||
       ' newest=' || (SELECT max(start_time)::text FROM cron.job_run_details) ||
       ' dead=' || (SELECT n_dead_tup::text FROM pg_stat_all_tables
                    WHERE schemaname='cron' AND relname='job_run_details') ||
       ' autovac_count=' || (SELECT autovacuum_count::text FROM pg_stat_all_tables
                    WHERE schemaname='cron' AND relname='job_run_details') ||
       ' last_autovacuum=' || (SELECT coalesce(last_autovacuum::text,'never')
                    FROM pg_stat_all_tables
                    WHERE schemaname='cron' AND relname='job_run_details')

UNION ALL
SELECT 'C_indexes', z.indexname, z.indexdef, ''
FROM (SELECT indexname, indexdef FROM pg_indexes
      WHERE schemaname = 'cron' AND tablename = 'job_run_details'
      ORDER BY indexname) z

UNION ALL
SELECT 'D_ownership',
       'table_owner / running_as / can_assume',
       pg_get_userbyid(c.relowner) || ' / ' || current_user || ' / ' ||
       pg_has_role(current_user, pg_get_userbyid(c.relowner), 'USAGE')::text,
       'if can_assume=false the indexes need the table owner (supabase_admin)'
FROM pg_class c
WHERE c.oid = 'cron.job_run_details'::regclass

UNION ALL
SELECT 'E_fallback_functions',
       fn,
       (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'private' AND p.proname = fn)::text,
       '1 = installed'
FROM (VALUES ('cron_job_run_details_cutoff'),
             ('prune_cron_job_run_details')) v(fn)

UNION ALL
SELECT 'F_runs_per_day', z.item, z.value, z.detail
FROM (SELECT jobname || ' @ ' || day::text AS item,
             runs::text AS value,
             'BEFORE the fix: detect-offline-users ran 16,962-17,006/day' AS detail
      FROM job_runs ORDER BY 1) z

UNION ALL
SELECT 'G_pg_stat_io', z.item, z.value, z.detail
FROM (SELECT i.backend_type || ' | ' || i.object || ' | ' || i.context AS item,
             pg_size_pretty(i.read_bytes::bigint) || ' read / ' ||
             pg_size_pretty(i.write_bytes::bigint) || ' write' AS value,
             'reads=' || i.reads || ' writes=' || i.writes ||
             ' writebacks=' || i.writebacks || ' hits=' || i.hits AS detail
      FROM pg_stat_io i
      WHERE (i.reads > 0 OR i.writes > 0 OR i.writebacks > 0)
        AND (i.context IN ('vacuum', 'bulkread') OR i.object = 'wal')
      ORDER BY 1) z

UNION ALL
SELECT 'G2_write_path', z.item, z.value, z.detail
FROM (SELECT i.backend_type || ' | ' || i.object || ' | ' || i.context AS item,
             pg_size_pretty(COALESCE(i.write_bytes, 0)::bigint) || ' write / ' ||
             pg_size_pretty(COALESCE(i.read_bytes, 0)::bigint) || ' read' AS value,
             'writes=' || COALESCE(i.writes::text, '0') ||
             ' writebacks=' || COALESCE(i.writebacks::text, '0') ||
             ' fsyncs=' || COALESCE(i.fsyncs::text, '0') AS detail
      FROM pg_stat_io i
      WHERE COALESCE(i.writebacks, 0) > 0
         OR (i.object = 'wal' AND COALESCE(i.writes, 0) > 0)
      ORDER BY 1) z

UNION ALL
SELECT 'H_wal_rate', 'wal_mb_per_day',
       (SELECT round((wal_bytes::numeric
             / NULLIF(EXTRACT(EPOCH FROM (now() - (SELECT stats_reset FROM pg_stat_wal)))
                      / 86400.0, 0)) / 1048576.0, 2)::text
        FROM pg_stat_wal),
       'was 84.03 MB/day before the fix'

UNION ALL
SELECT 'I_checked_at', 'now()', (SELECT checked_at::text FROM meta), '';

-- Note on [G]: pg_stat_io counters reset on crash recovery, so the numbers
-- are since the last restart, not since the migration. Compare the
-- vacuum/bulkread rows against the pre-fix baseline:
--   client backend | relation | vacuum    was 53,990 reads (422 MB)
--   client backend | relation | bulkread  was 59,098 reads (462 MB)
--   background worker | relation | bulkread was 22,551 reads (176 MB)
