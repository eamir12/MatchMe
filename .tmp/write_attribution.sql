-- =============================================================================
-- Write-path attribution: ONE statement, ONE result set.
-- Run this on 2026-10-21 (baseline) and again in 7 days to difference it.
--
-- NOTE: if this errors with 'relation "extensions.pg_stat_statements" does not
-- exist', change every "extensions.pg_stat_statements" to "public.pg_stat_statements".
--
-- What each section answers:
--   A  which TABLE the disk reads belong to (pg_statio has no write counter,
--      so this is the read side of the 1,017 MB of checkpoint writeback)
--   B  which INDEX is being read (missing-index detection)
--   C  the write path itself (pg_stat_io: who wrote and how much)
--   D  tables that are seq-scanned instead of indexed (CPU, not I/O)
--   E  top statements by disk read
--   F  top statements by total time (CPU burn)
--   G  statements called often but returning almost nothing (pure waste)
--   H  cron history table state
--   I  the counters to difference against next week
-- =============================================================================
WITH
  -- pg_stat_io gained read_bytes/write_bytes/extend_bytes only in PG18.
  -- PG16/17 have op_bytes (bytes per I/O unit) instead. Going through to_jsonb
  -- means a missing column yields NULL instead of a parse error, so one
  -- statement works on every version.
  io AS (
    SELECT s.j,
           COALESCE(NULLIF(s.j->>'read_bytes',   '')::numeric,
                    (s.j->>'reads')::numeric
                      * COALESCE(NULLIF(s.j->>'op_bytes','')::numeric, 8192)) AS read_bytes,
           COALESCE(NULLIF(s.j->>'write_bytes',  '')::numeric,
                    (s.j->>'writes')::numeric
                      * COALESCE(NULLIF(s.j->>'op_bytes','')::numeric, 8192)) AS write_bytes,
           COALESCE(NULLIF(s.j->>'extend_bytes', '')::numeric,
                    (s.j->>'extends')::numeric
                      * COALESCE(NULLIF(s.j->>'op_bytes','')::numeric, 8192)) AS extend_bytes,
           s.j->>'backend_type' AS backend_type,
           s.j->>'object'       AS object,
           s.j->>'context'      AS context,
           s.j->>'reads'        AS reads,
           s.j->>'writes'       AS writes,
           s.j->>'writebacks'   AS writebacks,
           s.j->>'extends'      AS extends,
           s.j->>'hits'         AS hits,
           s.j->>'fsyncs'       AS fsyncs
    FROM (SELECT to_jsonb(t) AS j FROM pg_stat_io t) s),
  st AS (SELECT * FROM extensions.pg_stat_statements),
  tbl AS (
    SELECT s.schemaname, s.relname,
           pg_total_relation_size(s.relid) AS bytes,
           s.heap_blks_read, s.heap_blks_hit, s.idx_blks_read, s.idx_blks_hit,
           coalesce(t.n_live_tup, 0) AS n_live_tup,
           coalesce(t.n_dead_tup, 0) AS n_dead_tup
    FROM pg_statio_all_tables s
    LEFT JOIN pg_stat_all_tables t
           ON t.relid = s.relid
    WHERE s.schemaname NOT IN ('pg_catalog', 'information_schema')
      AND s.schemaname NOT LIKE 'pg_toast%'
      AND s.schemaname NOT LIKE 'pg_temp%'),
  idx AS (
    SELECT schemaname, relname, indexrelname, idx_blks_read, idx_blks_hit,
           pg_relation_size(indexrelid) AS bytes
    FROM pg_statio_user_indexes
    WHERE idx_blks_read > 0),
  scan AS (
    SELECT schemaname, relname, seq_scan, seq_tup_read, idx_scan,
           pg_total_relation_size(relid) AS bytes,
           n_live_tup, n_dead_tup
    FROM pg_stat_all_tables
    WHERE seq_scan > 0
      AND schemaname NOT IN ('pg_catalog', 'information_schema')
      AND schemaname NOT LIKE 'pg_toast%'
      AND schemaname NOT LIKE 'pg_temp%')

SELECT 'A_table_disk_reads' AS section,
       z.schemaname || '.' || z.relname AS item,
       pg_size_pretty(z.heap_blks_read * 8192) || ' heap + ' ||
       pg_size_pretty(z.idx_blks_read * 8192) || ' index' AS value,
       'size=' || pg_size_pretty(z.bytes) ||
       ' cache_hit=' ||
       round(100.0 * z.heap_blks_hit / NULLIF(z.heap_blks_read + z.heap_blks_hit, 0), 2)::text || '%' ||
       ' live=' || z.n_live_tup || ' dead=' || z.n_dead_tup
FROM (SELECT t.*, (t.heap_blks_read + t.idx_blks_read) AS blocks
      FROM tbl t ORDER BY 2 DESC LIMIT 15) z

UNION ALL
SELECT 'B_index_disk_reads', z.schemaname || '.' || z.indexrelname,
       pg_size_pretty(z.idx_blks_read * 8192),
       'on ' || z.relname || ' | size=' || pg_size_pretty(z.bytes) ||
       ' cache_hit=' ||
       round(100.0 * z.idx_blks_hit / NULLIF(z.idx_blks_read + z.idx_blks_hit, 0), 2)::text || '%'
FROM (SELECT * FROM idx ORDER BY idx_blks_read DESC LIMIT 10) z

UNION ALL
SELECT 'C_write_path', z.backend_type || ' | ' || z.object || ' | ' || z.context,
       pg_size_pretty(z.write_bytes::bigint) || ' written / ' ||
       pg_size_pretty(z.read_bytes::bigint) || ' read',
       'writes=' || coalesce(z.writes, '0') ||
       ' writebacks=' || coalesce(z.writebacks, '0') ||
       ' extends=' || coalesce(z.extends, '0') ||
       ' fsyncs=' || coalesce(z.fsyncs, '0') ||
       ' | the checkpointer row is the 1,017 MB of dirty-page writeback'
FROM (SELECT * FROM io
      WHERE COALESCE((j->>'writebacks')::bigint, 0) > 0
         OR COALESCE((j->>'writes')::bigint, 0) > 0
      ORDER BY (COALESCE(write_bytes, 0) + COALESCE(read_bytes, 0)) DESC LIMIT 12) z

UNION ALL
SELECT 'D_seq_scan_offenders', z.schemaname || '.' || z.relname,
       z.seq_tup_read::text || ' rows seq-scanned',
       'seq_scan=' || z.seq_scan || ' idx_scan=' || z.idx_scan ||
       ' size=' || pg_size_pretty(z.bytes) ||
       ' | ' || round(100.0 * z.seq_scan / NULLIF(z.seq_scan + z.idx_scan, 0), 1)::text || '% seq'
FROM (SELECT * FROM scan ORDER BY seq_tup_read DESC LIMIT 12) z

UNION ALL
SELECT 'E_stmt_by_reads', left(regexp_replace(z.query, '\s+', ' ', 'g'), 90),
       pg_size_pretty(z.shared_blks_read * 8192),
       'calls=' || z.calls || ' rows=' || z.rows ||
       ' mean_ms=' || round(z.mean_exec_time::numeric, 2)
FROM (SELECT * FROM st WHERE shared_blks_read > 0 ORDER BY shared_blks_read DESC LIMIT 8) z

UNION ALL
SELECT 'F_stmt_by_time', left(regexp_replace(z.query, '\s+', ' ', 'g'), 90),
       round(z.total_exec_time::numeric / 1000, 1)::text || ' s total',
       'calls=' || z.calls || ' mean_ms=' || round(z.mean_exec_time::numeric, 2) ||
       ' rows=' || z.rows
FROM (SELECT * FROM st WHERE calls > 0 ORDER BY total_exec_time DESC LIMIT 8) z

UNION ALL
SELECT 'G_wasteful_calls', left(regexp_replace(z.query, '\s+', ' ', 'g'), 90),
       z.calls::text || ' calls, ' || z.rows::text || ' rows',
       round((z.rows::numeric / NULLIF(z.calls, 0))::numeric, 2)::text || ' rows/call' ||
       ' | read=' || pg_size_pretty(z.shared_blks_read * 8192) ||
       ' | total_ms=' || round(z.total_exec_time::numeric, 1)
FROM (SELECT * FROM st
      WHERE calls > 1000 AND rows::numeric / NULLIF(calls, 0) < 5
      ORDER BY shared_blks_read DESC LIMIT 8) z

UNION ALL
SELECT 'H_cron_history', 'cron.job_run_details',
       pg_size_pretty(pg_total_relation_size('cron.job_run_details')) || ' / ' ||
       (SELECT count(*) FROM cron.job_run_details)::text || ' rows',
       'dead=' || (SELECT n_dead_tup::text FROM pg_stat_all_tables
                   WHERE schemaname='cron' AND relname='job_run_details') ||
       ' autovac=' || (SELECT autovacuum_count::text FROM pg_stat_all_tables
                   WHERE schemaname='cron' AND relname='job_run_details') ||
       ' | 147 MB / 604,072 rows on 2026-10-21, sheds ~15,400/day'
UNION ALL
SELECT 'H_cron_history', 'active cron jobs',
       (SELECT count(*)::text FROM cron.job WHERE active),
       'runtimes: ' || (SELECT string_agg(COALESCE(to_jsonb(j)->>'jobname','(unnamed)') || '=' || j.schedule, ', ')
                        FROM cron.job j WHERE j.active)

UNION ALL
SELECT 'I_baseline', 'pg_stat_statements window start',
       (SELECT stats_reset::text FROM extensions.pg_stat_statements_info),
       'difference these counters in 7 days to see the fix land'
UNION ALL
SELECT 'I_baseline', 'tracked reads / writes',
       pg_size_pretty((SELECT sum(shared_blks_read) * 8192 FROM st)) || ' / ' ||
       pg_size_pretty((SELECT sum(shared_blks_written) * 8192 FROM st)),
       'statements tracked=' || (SELECT count(*)::text FROM st)
UNION ALL
SELECT 'I_baseline', 'db-wide blks_read / blks_hit',
       (SELECT blks_read::text || ' / ' || blks_hit::text FROM pg_stat_database
        WHERE datname = current_database()),
       'db_stats_reset=' || (SELECT coalesce(stats_reset::text, 'never') FROM pg_stat_database
                              WHERE datname = current_database())
UNION ALL
SELECT 'I_baseline', 'wal bytes total',
       pg_size_pretty((SELECT wal_bytes FROM pg_stat_wal)),
       'wal_stats_reset=' || (SELECT stats_reset::text FROM pg_stat_wal)
