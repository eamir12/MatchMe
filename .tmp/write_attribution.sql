-- =============================================================================
-- READ-ONLY: attribute the 1,017 MB of checkpoint writeback that
-- pg_stat_statements explains only 3% of, and find scan-heavy statements.
-- Run AFTER applying the cron fix, and again a week later to compare.
-- =============================================================================

-- [W1] Per-table block I/O -- the missing attribution.
--      This is the only view that tells you WHICH table the writes belong to.
--      heap_blks_read = blocks fetched from the OS (cache misses).
--      Note: pg_statio has no "written" column; writes are attributed via
--      pg_stat_io (backend_type/object/context) instead.
SELECT schemaname,
       relname,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       heap_blks_read, heap_blks_hit,
       pg_size_pretty(heap_blks_read * 8192)          AS heap_read,
       idx_blks_read, idx_blks_hit,
       toast_blks_read, tidx_blks_read
FROM pg_statio_all_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND schemaname NOT LIKE 'pg_toast%'
  AND schemaname NOT LIKE 'pg_temp%'
ORDER BY heap_blks_read DESC
LIMIT 25;

-- [W1b] Same, but ranked by total blocks touched (read+hit is cache, so
--       read is the disk number; this ranks by "how much was not cached")
SELECT schemaname,
       relname,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       heap_blks_read + idx_blks_read AS blocks_from_disk,
       round(100.0 * heap_blks_read / NULLIF(heap_blks_read + heap_blks_hit, 0), 3)
                                                  AS heap_cache_hit_pct,
       round(100.0 * idx_blks_read / NULLIF(idx_blks_read + idx_blks_hit, 0), 3)
                                                  AS idx_cache_hit_pct
FROM pg_statio_all_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND schemaname NOT LIKE 'pg_toast%'
  AND schemaname NOT LIKE 'pg_temp%'
  AND (heap_blks_read + idx_blks_read) > 0
ORDER BY blocks_from_disk DESC
LIMIT 25;

-- [W1c] Per-index disk reads -- finds missing/ignored indexes
SELECT schemaname, relname, indexrelname,
       idx_blks_read, idx_blks_hit,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_statio_user_indexes
WHERE idx_blks_read > 0
ORDER BY idx_blks_read DESC
LIMIT 20;

-- [W2] Is anything vacuuming right now? (autovacuum vs your own jobs)
SELECT p.pid,
       p.phase,
       p.heap_blks_total, p.heap_blks_scanned, p.heap_blks_vacuumed,
       p.index_vacuum_count, p.num_dead_tuples,
       a.query AS query
FROM pg_stat_progress_vacuum p
LEFT JOIN pg_stat_activity a USING (pid);

-- [W3] Scan-heavy statements: many calls, few rows returned.
--      These are the "served from cache but still burning CPU" queries --
--      the ones pg_stat_io calls context='normal' with huge hit counts.
SELECT calls,
       rows,
       round(rows::numeric / NULLIF(calls, 0), 1) AS rows_per_call,
       shared_blks_read,
       pg_size_pretty(shared_blks_read * 8192) AS disk_read,
       round(mean_exec_time::numeric, 2)         AS mean_ms,
       left(regexp_replace(query, '\s+', ' ', 'g'), 120) AS query
FROM pg_stat_statements
WHERE calls > 1000
  AND rows::numeric / NULLIF(calls, 0) < 5
ORDER BY shared_blks_read DESC
LIMIT 20;

-- [W4] The same, but by total time spent (CPU burn, not I/O)
SELECT calls,
       round(total_exec_time::numeric / 1000, 1) AS total_seconds,
       round(mean_exec_time::numeric, 2)         AS mean_ms,
       rows,
       left(regexp_replace(query, '\s+', ' ', 'g'), 120) AS query
FROM pg_stat_statements
WHERE calls > 100
ORDER BY total_exec_time DESC
LIMIT 20;

-- [W5] Cron job inventory + the history table, post-fix
SELECT jobid, jobname, schedule, active,
       left(regexp_replace(command, '\s+', ' ', 'g'), 70) AS command
FROM cron.job
ORDER BY jobid;

SELECT pg_size_pretty(pg_total_relation_size('cron.job_run_details')) AS total_size,
       (SELECT count(*) FROM cron.job_run_details)                     AS live_rows,
       (SELECT min(start_time) FROM cron.job_run_details)              AS oldest,
       (SELECT max(start_time) FROM cron.job_run_details)              AS newest,
       (SELECT count(*) FROM pg_indexes
         WHERE schemaname = 'cron' AND tablename = 'job_run_details')  AS index_count;
