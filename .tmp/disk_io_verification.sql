-- =============================================================================
-- READ-ONLY verification of the "pg_stat_statements disk I/O" assessment.
-- Paste the whole file into the Supabase SQL Editor and run it once.
-- Then paste back the results for the sections marked [S1]..[S9].
-- =============================================================================

-- -----------------------------------------------------------------------------
-- [S0] Resolve pg_stat_statements (Supabase installs it in schema `extensions`).
--      Creates temp tables _pgss (statements) and _pgss_meta (settings).
-- -----------------------------------------------------------------------------
-- NOTE: no UPDATE/DELETE anywhere in this script. Everything is SELECT-only
-- against catalog + stats views, plus temp-table creation. Supabase's SQL
-- linter flags UPDATE without WHERE, so the metadata row is INSERTed, not
-- UPDATEd.
DO $$
DECLARE
  src       text;
  info_src  text;
  r_reset   timestamptz := NULL;
  r_dealloc bigint     := NULL;
BEGIN
  IF to_regclass('extensions.pg_stat_statements') IS NOT NULL THEN
    src := 'extensions.pg_stat_statements';
  ELSIF to_regclass('public.pg_stat_statements') IS NOT NULL THEN
    src := 'public.pg_stat_statements';
  END IF;

  IF src IS NOT NULL THEN
    EXECUTE format('CREATE TEMP TABLE _pgss AS SELECT * FROM %s', src);
  ELSE
    CREATE TEMP TABLE _pgss (
      query text, calls bigint, total_exec_time double precision, rows bigint,
      shared_blks_hit bigint, shared_blks_read bigint, shared_blks_dirtied bigint,
      shared_blks_written bigint, blk_read_time double precision, blk_write_time double precision);
    RAISE NOTICE 'pg_stat_statements NOT INSTALLED - _pgss is empty';
  END IF;

  CREATE TEMP TABLE _pgss_meta (
    stats_reset timestamptz, dealloc bigint, num_statements bigint,
    track text, track_utility text, track_planning text, track_io_timing text,
    max_entries text, pgss_shared_blks_read bigint, pgss_shared_blks_written bigint);

  IF to_regclass('extensions.pg_stat_statements_info') IS NOT NULL THEN
    info_src := 'extensions.pg_stat_statements_info';
  ELSIF to_regclass('public.pg_stat_statements_info') IS NOT NULL THEN
    info_src := 'public.pg_stat_statements_info';
  END IF;

  IF info_src IS NOT NULL THEN
    BEGIN
      EXECUTE format('SELECT stats_reset FROM %s LIMIT 1', info_src) INTO r_reset;
    EXCEPTION WHEN OTHERS THEN r_reset := NULL;
    END;
    BEGIN
      EXECUTE format('SELECT dealloc FROM %s LIMIT 1', info_src) INTO r_dealloc;
    EXCEPTION WHEN OTHERS THEN r_dealloc := NULL;
    END;
  END IF;

  INSERT INTO _pgss_meta (
    stats_reset, dealloc, num_statements, track, track_utility, track_planning,
    track_io_timing, max_entries, pgss_shared_blks_read, pgss_shared_blks_written)
  VALUES (
    r_reset, r_dealloc,
    (SELECT count(*) FROM _pgss),
    current_setting('pg_stat_statements.track', true),
    current_setting('pg_stat_statements.track_utility', true),
    current_setting('pg_stat_statements.track_planning', true),
    current_setting('track_io_timing', true),
    current_setting('pg_stat_statements.max', true),
    (SELECT COALESCE(sum(shared_blks_read),0) FROM _pgss),
    (SELECT COALESCE(sum(shared_blks_written),0) FROM _pgss));
END $$;

-- [S1] Settings + window + totals
SELECT
  current_setting('server_version')        AS pg_version,
  (SELECT stats_reset FROM _pgss_meta)      AS pgss_stats_reset,
  (SELECT dealloc FROM _pgss_meta)         AS pgss_evicted_entries,
  (SELECT num_statements FROM _pgss_meta)  AS pgss_rows_tracked,
  (SELECT max_entries FROM _pgss_meta)      AS pgss_max_entries,
  (SELECT track FROM _pgss_meta)            AS track,
  (SELECT track_utility FROM _pgss_meta)    AS track_utility,
  (SELECT track_planning FROM _pgss_meta)   AS track_planning,
  (SELECT track_io_timing FROM _pgss_meta)  AS track_io_timing,
  (SELECT pgss_shared_blks_read FROM _pgss_meta)    AS pgss_total_blks_read,
  pg_size_pretty((SELECT pgss_shared_blks_read * 8192 FROM _pgss_meta))      AS pgss_total_read,
  pg_size_pretty((SELECT pgss_shared_blks_written * 8192 FROM _pgss_meta))   AS pgss_total_written,
  CASE WHEN (SELECT stats_reset FROM _pgss_meta) IS NULL THEN NULL
       ELSE round((SELECT pgss_shared_blks_read * 8192 FROM _pgss_meta)
        / GREATEST(1, EXTRACT(EPOCH FROM (now() - (SELECT stats_reset FROM _pgss_meta)))), 1)
  END                                                                        AS read_bytes_per_sec;

-- [S1b] DATABASE-WIDE totals (the denominator the assessment never used)
-- NOTE: pg_stat_database has NO blks_written column. Read-side totals live
-- here; write-side totals live in pg_stat_bgwriter (see below).
SELECT datname,
       stats_reset,
       blks_read, blks_hit,
       pg_size_pretty(blks_read * 8192)      AS read_total,
       blk_read_time, blk_write_time,
       temp_files, pg_size_pretty(temp_bytes) AS temp_total,
       xact_commit, xact_rollback, tup_inserted, tup_updated, tup_deleted,
       deadlocks,
       CASE WHEN stats_reset IS NULL THEN NULL
            ELSE round(blks_read::numeric
                 / GREATEST(1, EXTRACT(EPOCH FROM (now() - stats_reset))), 2)
       END                                                 AS read_blocks_per_sec
FROM pg_stat_database
WHERE datname = current_database();

-- [S1c] Write-side database totals.
-- The write-path counters moved between versions:
--   PG15/16: pg_stat_bgwriter.buffers_checkpoint / .buffers_backend / .checkpoints_timed
--   PG17:    pg_stat_bgwriter loses buffers_checkpoint -> pg_stat_checkpointer.buffers_written
--   PG18:    pg_stat_bgwriter loses buffers_backend and pg_stat_wal loses wal_write/wal_sync
--            (those live in pg_stat_io now)
-- So every metric is resolved by trying candidate expressions in order.
DO $$
DECLARE
  spec   jsonb;
  rec    record;
  k      text; val text; src text; c text;
  j      int;
BEGIN
  CREATE TEMP TABLE _io_totals (k text, v text, src text);

  spec := '[
    {"k":"checkpoint_buffers_written","c":["SELECT buffers_written::text FROM pg_stat_checkpointer",
                                         "SELECT buffers_checkpoint::text FROM pg_stat_bgwriter"]},
    {"k":"buffers_clean","c":["SELECT buffers_clean::text FROM pg_stat_bgwriter"]},
    {"k":"buffers_alloc","c":["SELECT buffers_alloc::text FROM pg_stat_bgwriter"]},
    {"k":"buffers_backend","c":["SELECT buffers_backend::text FROM pg_stat_bgwriter",
                                "SELECT buffers_backend::text FROM pg_stat_checkpointer"]},
    {"k":"checkpoints_timed","c":["SELECT num_timed::text FROM pg_stat_checkpointer",
                                  "SELECT checkpoints_timed::text FROM pg_stat_bgwriter"]},
    {"k":"checkpoints_req","c":["SELECT num_requested::text FROM pg_stat_checkpointer",
                                "SELECT checkpoints_req::text FROM pg_stat_bgwriter"]},
    {"k":"checkpoint_write_time","c":["SELECT write_time::text FROM pg_stat_checkpointer",
                                      "SELECT checkpoint_write_time::text FROM pg_stat_bgwriter"]},
    {"k":"checkpoint_sync_time","c":["SELECT sync_time::text FROM pg_stat_checkpointer",
                                     "SELECT checkpoint_sync_time::text FROM pg_stat_bgwriter"]},
    {"k":"wal_records","c":["SELECT wal_records::text FROM pg_stat_wal"]},
    {"k":"wal_fpi","c":["SELECT wal_fpi::text FROM pg_stat_wal"]},
    {"k":"wal_bytes","c":["SELECT wal_bytes::text FROM pg_stat_wal"]},
    {"k":"wal_buffers_full","c":["SELECT wal_buffers_full::text FROM pg_stat_wal"]},
    {"k":"wal_write","c":["SELECT wal_write::text FROM pg_stat_wal"]},
    {"k":"wal_sync","c":["SELECT wal_sync::text FROM pg_stat_wal"]},
    {"k":"wal_write_time","c":["SELECT wal_write_time::text FROM pg_stat_wal"]},
    {"k":"wal_sync_time","c":["SELECT wal_sync_time::text FROM pg_stat_wal"]},
    {"k":"bgwriter_stats_reset","c":["SELECT stats_reset::text FROM pg_stat_bgwriter"]}
  ]'::jsonb;

  FOR rec IN SELECT * FROM jsonb_to_recordset(spec) AS t(k text, c text[]) LOOP
    k   := rec.k;
    val := NULL;
    src := 'not available on this version';
    FOR j IN 1 .. COALESCE(array_length(rec.c, 1), 0) LOOP
      c := rec.c[j];
      BEGIN
        EXECUTE c INTO val;
        src := c;
        EXIT;
      EXCEPTION WHEN OTHERS THEN
        val := NULL;
      END;
    END LOOP;
    INSERT INTO _io_totals VALUES (k, val, src);
  END LOOP;
END $$;

SELECT k, v, src FROM _io_totals ORDER BY k;

-- -----------------------------------------------------------------------------
-- [S2] Reproduce the assessment's top reads / writes
-- -----------------------------------------------------------------------------
SELECT 'READ' AS io,
       calls, rows,
       shared_blks_read AS blocks,
       pg_size_pretty(shared_blks_read * 8192) AS total,
       round(shared_blks_read::numeric / NULLIF(calls,0), 3) AS blk_per_call,
       round(total_exec_time::numeric, 1) AS total_ms,
       round(mean_exec_time::numeric, 2)  AS mean_ms,
       left(regexp_replace(query, '\s+', ' ', 'g'), 110) AS query
FROM _pgss
ORDER BY shared_blks_read DESC
LIMIT 15;

SELECT 'WRITE' AS io,
       calls, rows,
       shared_blks_written AS blocks,
       pg_size_pretty(shared_blks_written * 8192) AS total,
       round(shared_blks_written::numeric / NULLIF(calls,0), 3) AS blk_per_call,
       round(total_exec_time::numeric, 1) AS total_ms,
       left(regexp_replace(query, '\s+', ' ', 'g'), 110) AS query
FROM _pgss
ORDER BY shared_blks_written DESC
LIMIT 15;

-- [S2b] What share of DB-wide I/O do tracked statements explain?
-- Read side: pg_stat_statements vs pg_stat_database.blks_read (same counter).
-- Write side: pg_stat_statements.shared_blks_written counts blocks a backend
-- wrote back; pg_stat_bgwriter counts write requests issued. Close but not
-- identical -- read the ratio as directional, not exact.
WITH s AS (
  SELECT sum(shared_blks_read) AS r, sum(shared_blks_written) AS w FROM _pgss),
     d AS (SELECT blks_read, stats_reset FROM pg_stat_database WHERE datname = current_database()),
     b AS (SELECT (SELECT v::numeric FROM _io_totals WHERE k = 'checkpoint_buffers_written') +
                  COALESCE((SELECT v::numeric FROM _io_totals WHERE k = 'buffers_clean'), 0) +
                  COALESCE((SELECT v::numeric FROM _io_totals WHERE k = 'buffers_backend'), 0) AS wbuf)
SELECT s.r AS pgss_blocks_read, d.blks_read AS db_blocks_read,
       round(100.0 * s.r / NULLIF(d.blks_read,0), 2) AS pct_of_db_reads,
       s.w AS pgss_blocks_written, b.wbuf AS bgwriter_blocks_written,
       round(100.0 * s.w / NULLIF(b.wbuf,0), 2) AS pct_of_db_writes,
       d.stats_reset AS db_stats_reset,
       (SELECT stats_reset FROM _pgss_meta) AS pgss_stats_reset,
       -- if the two windows differ a lot, the ratio above is not meaningful
       (d.stats_reset = (SELECT stats_reset FROM _pgss_meta)) AS windows_aligned
FROM s, d, b;

-- -----------------------------------------------------------------------------
-- [S3] pg_stat_io (PostgreSQL 16+): the authoritative per-context I/O breakdown.
--      empty result => PG15 or older, fall back to [S4].
--      PG18 added read_bytes/write_bytes/extend_bytes; PG16/17 only have counts.
--      The view below normalizes both shapes.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  has_bytes boolean := false;
  bs        bigint;
  defs      text[];
  i         int;
BEGIN
  IF to_regclass('pg_stat_io') IS NOT NULL THEN
    SELECT current_setting('block_size')::bigint INTO bs;

    -- Candidate view definitions, tried in order; first one that parses wins.
    --   [1] PG18+ : explicit read_bytes / write_bytes / extend_bytes columns
    --   [2] PG16/17: single op_bytes column (bytes per I/O unit)
    defs := ARRAY[
      'CREATE TEMP VIEW _io AS
       SELECT backend_type, object, context, reads, writes, writebacks, extends,
              hits, evictions, reuses, fsyncs,
              COALESCE(read_bytes,  reads  * ' || bs || ')::numeric AS read_bytes,
              COALESCE(write_bytes, writes * ' || bs || ')::numeric AS write_bytes,
              COALESCE(extend_bytes, extends * ' || bs || ')::numeric AS extend_bytes,
              stats_reset
       FROM pg_stat_io',
      'CREATE TEMP VIEW _io AS
       SELECT backend_type, object, context, reads, writes, writebacks, extends,
              hits, evictions, reuses, fsyncs,
              (reads   * op_bytes)::numeric AS read_bytes,
              (writes  * op_bytes)::numeric AS write_bytes,
              (extends * op_bytes)::numeric AS extend_bytes,
              stats_reset
       FROM pg_stat_io'
    ];

    FOR i IN 1 .. array_length(defs, 1) LOOP
      BEGIN
        EXECUTE defs[i];
        EXIT;
      EXCEPTION WHEN OTHERS THEN
        NULL;  -- try the next candidate
      END;
    END LOOP;
  ELSE
    EXECUTE 'CREATE TEMP VIEW _io AS
             SELECT NULL::text AS backend_type, NULL::text AS object, NULL::text AS context,
                    0::bigint AS reads, 0::bigint AS writes, 0::bigint AS writebacks,
                    0::bigint AS extends, 0::bigint AS hits, 0::bigint AS evictions,
                    0::bigint AS reuses, 0::bigint AS fsyncs,
                    0::numeric AS read_bytes, 0::numeric AS write_bytes,
                    0::numeric AS extend_bytes,
                    NULL::timestamptz AS stats_reset WHERE false';
    RAISE NOTICE 'pg_stat_io unavailable (needs PostgreSQL 16+)';
  END IF;
END $$;

SELECT backend_type, object, context,
       reads, writes, writebacks, extends, hits, evictions, reuses, fsyncs,
       pg_size_pretty(read_bytes::bigint)   AS read_total,
       pg_size_pretty(write_bytes::bigint)  AS write_total,
       pg_size_pretty(extend_bytes::bigint) AS extend_total
FROM _io
WHERE reads > 0 OR writes > 0 OR writebacks > 0 OR extends > 0
ORDER BY (COALESCE(read_bytes,0) + COALESCE(write_bytes,0) + COALESCE(extend_bytes,0)) DESC
LIMIT 40;

-- -----------------------------------------------------------------------------
-- [S4] WAL / checkpoint / temp-file I/O (usually the real "disk budget" driver)
-- Resolved via _io_totals so it works on PG15..PG18 (see [S1c] for why).
SELECT k AS metric, v AS value, src
FROM _io_totals
WHERE k LIKE 'wal_%' OR k LIKE 'checkpoint%' OR k LIKE 'buffers_%'
ORDER BY k;

-- [S4b] WAL rate since reset (bytes/day) -- the number that usually matters
SELECT
  (SELECT v::numeric FROM _io_totals WHERE k = 'wal_bytes')                        AS wal_bytes_total,
  (SELECT v::numeric FROM _io_totals WHERE k = 'wal_records')                      AS wal_records_total,
  (SELECT stats_reset FROM pg_stat_wal)                                           AS wal_stats_reset,
  pg_size_pretty((SELECT v::numeric FROM _io_totals WHERE k = 'wal_bytes'))        AS wal_total,
  CASE WHEN (SELECT stats_reset FROM pg_stat_wal) IS NULL THEN NULL
       ELSE round((SELECT v::numeric FROM _io_totals WHERE k = 'wal_bytes')
            / NULLIF(EXTRACT(EPOCH FROM (now() - (SELECT stats_reset FROM pg_stat_wal)))
                     / 86400.0, 0)
            / 1048576.0, 2)
  END                                                                             AS wal_mb_per_day;

-- -----------------------------------------------------------------------------
-- [S5] cron.job_run_details forensics
-- -----------------------------------------------------------------------------
-- job inventory (does the 02:00 cleanup / 02:10 vacuum claim hold?)
-- to_jsonb()->>'jobname' keeps this working on pg_cron < 1.5 (no jobname column)
SELECT j.jobid,
       to_jsonb(j)->>'jobname' AS jobname,
       j.schedule,
       j.active,
       left(regexp_replace(j.command, '\s+', ' ', 'g'), 160) AS command
FROM cron.job j
ORDER BY j.jobid;

-- rows written into the history table per day, per job
SELECT date_trunc('day', start_time)::date AS day,
       jobid,
       count(*)                                    AS runs,
       pg_size_pretty(count(*) * 8::bigint)         AS approx_rows_pgsize,
       round(avg(length(command)))                 AS avg_cmd_bytes
FROM cron.job_run_details
WHERE start_time > now() - interval '7 days'
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC
LIMIT 40;

-- table size / bloat / indexes
SELECT pg_size_pretty(pg_total_relation_size('cron.job_run_details')) AS total_size,
       pg_size_pretty(pg_relation_size('cron.job_run_details'))      AS heap_size,
       (SELECT count(*) FROM cron.job_run_details)                   AS live_rows,
       (SELECT min(start_time) FROM cron.job_run_details)            AS oldest_row,
       (SELECT max(start_time) FROM cron.job_run_details)            AS newest_row,
       (SELECT avg(length(command))::int FROM cron.job_run_details)  AS avg_cmd_bytes,
       (SELECT max(length(command)) FROM cron.job_run_details)       AS max_cmd_bytes;

SELECT indexname, indexdef FROM pg_indexes
WHERE schemaname = 'cron' AND tablename = 'job_run_details';

SELECT n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_vacuum, last_autovacuum, vacuum_count, autovacuum_count,
       last_analyze, last_autoanalyze, autoanalyze_count
FROM pg_stat_all_tables
WHERE schemaname = 'cron' AND relname = 'job_run_details';

-- -----------------------------------------------------------------------------
-- [S6] Churn tables the assessment never looked at
--      (Realtime subscriptions/messages + the minutely health-snapshot table)
-- -----------------------------------------------------------------------------
SELECT n.nspname AS schema, c.relname AS table,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
       st.n_live_tup, st.n_dead_tup, st.n_tup_ins, st.n_tup_del,
       st.seq_scan, st.idx_scan,
       st.last_autovacuum, st.autovacuum_count
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_all_tables st ON st.relid = c.oid
WHERE c.relkind = 'r'
  AND (n.nspname = 'realtime'
       OR (n.nspname = 'public' AND c.relname IN ('admin_health_snapshots')))
ORDER BY pg_total_relation_size(c.oid) DESC;

-- -----------------------------------------------------------------------------
-- [S7] Largest tables in the database + their bloat/autovacuum state
-- -----------------------------------------------------------------------------
SELECT schemaname, relname,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       seq_scan, seq_tup_read, idx_scan,
       n_tup_ins, n_tup_upd, n_tup_del,
       last_autovacuum, autovacuum_count, last_autoanalyze
FROM pg_stat_all_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
    AND schemaname NOT LIKE 'pg_toast%'
    AND schemaname NOT LIKE 'pg_temp%'
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 25;

-- [S7b] Tables that actually got scanned (seq_scan heavy = hidden read I/O)
SELECT schemaname, relname,
       seq_scan, seq_tup_read, idx_scan,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       round(100.0 * seq_scan / NULLIF(seq_scan + idx_scan, 0), 1) AS seq_pct
FROM pg_stat_all_tables
WHERE seq_scan > 0
  AND schemaname NOT IN ('pg_catalog', 'information_schema')
  AND schemaname NOT LIKE 'pg_toast%'
  AND schemaname NOT LIKE 'pg_temp%'
ORDER BY seq_tup_read DESC
LIMIT 20;

-- -----------------------------------------------------------------------------
-- [S8] Replication + WAL shipping (the part that turns local writes into
--      "disk IO" on Supabase: replicas, logflare, queue, PITR archive)
-- -----------------------------------------------------------------------------
SELECT application_name, state, sync_state, write_lag, flush_lag, replay_lag
FROM pg_stat_replication;

-- subscription definition (catalog, stable across PG15..PG18)
SELECT subname, subenabled, subslotname FROM pg_subscription;

-- per-relation replication detail (view shape changed in PG16/PG18, so only
-- use columns that exist in all of them)
SELECT subname, worker_type, pid, relid, received_lsn, latest_end_lsn
FROM pg_stat_subscription
ORDER BY subname, relid;

-- -----------------------------------------------------------------------------
-- [S8b] Replication slots -- a lagging logical slot pins WAL on disk.
--      Supabase Realtime keeps a slot for realtime.messages (visible in the
--      [S9] output as START_REPLICATION SLOT supabase_realtime_messages_...).
-- -----------------------------------------------------------------------------
SELECT slot_name, slot_type, plugin, database, active,
       wal_status,
       pg_size_pretty(safe_wal_size) AS safe_wal_size,
       restart_lsn, confirmed_flush_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_pinned
FROM pg_replication_slots
ORDER BY slot_name;

-- -----------------------------------------------------------------------------
-- [S9] Anything big running right now
-- -----------------------------------------------------------------------------
SELECT pid, state, wait_event_type, wait_event,
       now() - query_start AS runtime,
       left(regexp_replace(query, '\s+', ' ', 'g'), 120) AS query
FROM pg_stat_activity
WHERE datname = current_database()
  AND state <> 'idle'
  AND pid <> pg_backend_pid()
ORDER BY query_start
LIMIT 15;

-- =============================================================================
-- [REPORT] ONE consolidated result set.
-- The Supabase SQL Editor only surfaces the LAST result set of a batch, so this
-- final statement re-emits every finding as (section, item, value, detail).
-- This is the result to paste back.
-- =============================================================================
WITH
  meta AS (
    SELECT stats_reset, dealloc, num_statements, track, track_utility,
           track_planning, track_io_timing, max_entries,
           pgss_shared_blks_read, pgss_shared_blks_written
    FROM _pgss_meta),
  dbi AS (
    SELECT * FROM pg_stat_database WHERE datname = current_database()),
  s AS (
    SELECT sum(shared_blks_read) AS r, sum(shared_blks_written) AS w FROM _pgss),
  wt AS (
    SELECT COALESCE((SELECT v::numeric FROM _io_totals WHERE k = 'checkpoint_buffers_written'), 0)
         + COALESCE((SELECT v::numeric FROM _io_totals WHERE k = 'buffers_clean'), 0)
         + COALESCE((SELECT v::numeric FROM _io_totals WHERE k = 'buffers_backend'), 0) AS bgw),
  wal AS (
    SELECT v::numeric AS bytes FROM _io_totals WHERE k = 'wal_bytes'),
  wals AS (
    SELECT stats_reset FROM pg_stat_wal)

SELECT 'S1_settings' AS section, 'postgres_version' AS item,
       current_setting('server_version') AS value, ''::text AS detail
UNION ALL
SELECT 'S1_settings', 'pgss_stats_reset', meta.stats_reset::text,
       'pg_stat_statements counters since here'
FROM meta
UNION ALL
SELECT 'S1_settings', 'pgss_evicted_entries', meta.dealloc::text,
       'entries evicted (max ' || meta.max_entries || ')'
FROM meta
UNION ALL
SELECT 'S1_settings', 'pgss_track', meta.track,
       'track_utility=' || meta.track_utility ||
       ' track_io_timing=' || meta.track_io_timing ||
       ' | track=top => statements inside functions are NOT counted separately'
FROM meta
UNION ALL
SELECT 'S1_settings', 'pgss_statements_tracked', meta.num_statements::text,
       'distinct query texts captured'
FROM meta
UNION ALL
SELECT 'S1_settings', 'pgss_total_read',
       pg_size_pretty(meta.pgss_shared_blks_read * 8192), 'all tracked statements'
FROM meta
UNION ALL
SELECT 'S1_settings', 'pgss_total_written',
       pg_size_pretty(meta.pgss_shared_blks_written * 8192), 'all tracked statements'
FROM meta
UNION ALL
SELECT 'S1_settings', 'pgss_read_bytes_per_sec',
       CASE WHEN meta.stats_reset IS NULL THEN NULL
            ELSE round(meta.pgss_shared_blks_read * 8192::numeric
                 / GREATEST(1, EXTRACT(EPOCH FROM (now() - meta.stats_reset))), 1)::text END,
       'average rate over the window'
FROM meta

UNION ALL
SELECT 'S1b_database', 'blks_read', dbi.blks_read::text,
       'DB-WIDE reads (all sources)'
FROM dbi
UNION ALL
SELECT 'S1b_database', 'blks_hit', dbi.blks_hit::text, 'shared buffer hits'
FROM dbi
UNION ALL
SELECT 'S1b_database', 'read_total',
       pg_size_pretty(dbi.blks_read * 8192), 'approx physical read volume'
FROM dbi
UNION ALL
SELECT 'S1b_database', 'temp_files', dbi.temp_files::text,
       pg_size_pretty(dbi.temp_bytes) || ' spilled to disk'
FROM dbi
UNION ALL
SELECT 'S1b_database', 'xact_commit / rollback',
       dbi.xact_commit::text || ' / ' || dbi.xact_rollback::text,
       'since ' || coalesce(dbi.stats_reset::text, 'unknown')
FROM dbi
UNION ALL
SELECT 'S1b_database', 'tup_inserted/upd/deleted',
       dbi.tup_inserted::text || ' / ' || dbi.tup_updated::text || ' / ' || dbi.tup_deleted::text,
       'row churn drives WAL + bloat'
FROM dbi
UNION ALL
SELECT 'S1b_database', 'db_stats_reset', coalesce(dbi.stats_reset::text, 'never'),
       'if never, per-second rates are unavailable'
FROM dbi

UNION ALL
SELECT 'S1c_writes', m.k, m.v, m.src
FROM _io_totals m
WHERE m.k IN ('checkpoint_buffers_written', 'buffers_clean', 'buffers_backend',
              'checkpoints_timed', 'checkpoints_req', 'wal_bytes', 'wal_records',
              'wal_fpi', 'wal_buffers_full', 'wal_write', 'wal_sync')

UNION ALL
SELECT 'S2b_coverage', 'pgss_blocks_read vs db_blocks_read',
       s.r::text || ' vs ' || dbi.blks_read::text,
       'pct of DB reads explained by tracked statements = ' ||
       round(100.0 * s.r / NULLIF(dbi.blks_read, 0), 2)::text
FROM s, dbi
UNION ALL
SELECT 'S2b_coverage', 'pgss_blocks_written vs bgwriter',
       s.w::text || ' vs ' || wt.bgw::text,
       'pct of DB writes explained by tracked statements = ' ||
       round(100.0 * s.w / NULLIF(wt.bgw, 0), 2)::text
FROM s, wt
UNION ALL
SELECT 'S2b_coverage', 'windows_aligned',
       (dbi.stats_reset = (SELECT stats_reset FROM meta))::text,
       'db_stats_reset=' || coalesce(dbi.stats_reset::text, 'never') ||
       ' pgss_stats_reset=' || coalesce((SELECT stats_reset::text FROM meta), 'never')
FROM dbi

UNION ALL
SELECT 'S2_top_reads', t.item, t.value, t.detail
FROM (SELECT left(regexp_replace(x.query, '\s+', ' ', 'g'), 130) AS item,
             x.shared_blks_read::text || ' blocks = ' || pg_size_pretty(x.shared_blks_read * 8192) AS value,
             'calls=' || x.calls || ' rows=' || x.rows ||
             ' mean_ms=' || round(x.mean_exec_time::numeric, 2) AS detail
      FROM (SELECT * FROM _pgss ORDER BY shared_blks_read DESC LIMIT 12) x) t
UNION ALL
SELECT 'S2_top_writes', t.item, t.value, t.detail
FROM (SELECT left(regexp_replace(x.query, '\s+', ' ', 'g'), 130) AS item,
             x.shared_blks_written::text || ' blocks = ' || pg_size_pretty(x.shared_blks_written * 8192) AS value,
             'calls=' || x.calls || ' rows=' || x.rows ||
             ' mean_ms=' || round(x.mean_exec_time::numeric, 2) AS detail
      FROM (SELECT * FROM _pgss ORDER BY shared_blks_written DESC LIMIT 12) x) t

UNION ALL
SELECT 'S3_pg_stat_io', z.item, z.value, z.detail
FROM (SELECT i.backend_type || ' | ' || i.object || ' | ' || i.context AS item,
             pg_size_pretty(COALESCE(i.read_bytes, 0)::bigint) || ' read / ' ||
             pg_size_pretty(COALESCE(i.write_bytes, 0)::bigint) || ' write / ' ||
             pg_size_pretty(COALESCE(i.extend_bytes, 0)::bigint) || ' extend' AS value,
             'reads=' || COALESCE(i.reads::text, '0') ||
             ' writes=' || COALESCE(i.writes::text, '0') ||
             ' writebacks=' || COALESCE(i.writebacks::text, '0') ||
             ' extends=' || COALESCE(i.extends::text, '0') ||
             ' hits=' || COALESCE(i.hits::text, '0') ||
             ' fsyncs=' || COALESCE(i.fsyncs::text, '0') AS detail
      FROM _io i
      WHERE i.reads > 0 OR i.writes > 0 OR i.writebacks > 0 OR i.extends > 0
      ORDER BY (COALESCE(i.read_bytes, 0) + COALESCE(i.write_bytes, 0)
                + COALESCE(i.extend_bytes, 0)) DESC) z

UNION ALL
SELECT 'S4b_wal_rate', 'wal_mb_per_day',
       CASE WHEN wals.stats_reset IS NULL THEN NULL
            ELSE round(wal.bytes
                 / NULLIF(EXTRACT(EPOCH FROM (now() - wals.stats_reset)) / 86400.0, 0)
                 / 1048576.0, 2)::text END,
       'WAL generated per day since ' || coalesce(wals.stats_reset::text, 'unknown')
FROM wal, wals

UNION ALL
SELECT 'S5_cron_table', 'size / rows',
       pg_size_pretty(pg_total_relation_size('cron.job_run_details')) || ' / ' ||
       (SELECT count(*) FROM cron.job_run_details)::text,
       'heap=' || pg_size_pretty(pg_relation_size('cron.job_run_details')) ||
       ' oldest=' || (SELECT min(start_time)::text FROM cron.job_run_details) ||
       ' newest=' || (SELECT max(start_time)::text FROM cron.job_run_details)
UNION ALL
SELECT 'S5_cron_table', 'command_text_bytes',
       (SELECT avg(length(command))::int::text FROM cron.job_run_details) || ' avg / ' ||
       (SELECT max(length(command))::text FROM cron.job_run_details) || ' max',
       'every run stores the full job SQL in cron.job_run_details.command'
UNION ALL
SELECT 'S5_cron_table', 'dead_tuples / bloat',
       (SELECT n_dead_tup::text || ' dead / ' || n_live_tup::text || ' live'
        FROM pg_stat_all_tables WHERE schemaname = 'cron' AND relname = 'job_run_details'),
       'last_autovacuum=' ||
       (SELECT coalesce(last_autovacuum::text, 'never')
        FROM pg_stat_all_tables WHERE schemaname = 'cron' AND relname = 'job_run_details') ||
       ' autovacuum_count=' ||
       (SELECT autovacuum_count::text
        FROM pg_stat_all_tables WHERE schemaname = 'cron' AND relname = 'job_run_details')
UNION ALL
SELECT 'S5_cron_jobs', z.item, z.value, z.detail
FROM (SELECT coalesce(to_jsonb(j)->>'jobname', '(unnamed)') AS item,
             'schedule=' || j.schedule || ' active=' || j.active AS value,
             left(regexp_replace(j.command, '\s+', ' ', 'g'), 140) AS detail
      FROM cron.job j ORDER BY j.jobid) z
UNION ALL
SELECT 'S5_cron_runs_per_day', z.item, z.value, z.detail
FROM (SELECT 'day=' || c.d || ' jobid=' || c.jobid AS item,
             c.runs::text || ' runs' AS value,
             'avg_cmd_bytes=' || c.avg_cmd AS detail
      FROM (SELECT date_trunc('day', start_time)::date AS d, jobid,
                   count(*) AS runs, round(avg(length(command))) AS avg_cmd
            FROM cron.job_run_details
            WHERE start_time > now() - interval '7 days'
            GROUP BY 1, 2) c
      ORDER BY c.d DESC, c.runs DESC LIMIT 30) z
UNION ALL
SELECT 'S5_cron_indexes', i.indexname, i.indexdef, ''
FROM pg_indexes i WHERE i.schemaname = 'cron' AND i.tablename = 'job_run_details'

UNION ALL
SELECT 'S6_churn_tables', z.item, z.value, z.detail
FROM (SELECT n.nspname || '.' || c.relname AS item,
             pg_size_pretty(pg_total_relation_size(c.oid)) AS value,
             'live=' || coalesce(st.n_live_tup::text, '?') ||
             ' dead=' || coalesce(st.n_dead_tup::text, '?') ||
             ' ins=' || coalesce(st.n_tup_ins::text, '?') ||
             ' seq_scan=' || coalesce(st.seq_scan::text, '?') ||
             ' idx_scan=' || coalesce(st.idx_scan::text, '?') AS detail
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_stat_all_tables st ON st.relid = c.oid
      WHERE c.relkind = 'r'
        AND (n.nspname = 'realtime'
             OR (n.nspname = 'public' AND c.relname IN ('admin_health_snapshots')))
      ORDER BY pg_total_relation_size(c.oid) DESC) z

UNION ALL
SELECT 'S7_top_tables', z.item, z.value, z.detail
FROM (SELECT t.schemaname || '.' || t.relname AS item,
             pg_size_pretty(pg_total_relation_size(t.relid)) AS value,
             'live=' || t.n_live_tup || ' dead=' || t.n_dead_tup ||
             ' seq_scan=' || t.seq_scan || ' seq_tup_read=' || t.seq_tup_read ||
             ' idx_scan=' || t.idx_scan || ' autovac=' || t.autovacuum_count AS detail
      FROM (SELECT * FROM pg_stat_all_tables
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
              AND schemaname NOT LIKE 'pg_toast%'
              AND schemaname NOT LIKE 'pg_temp%'
            ORDER BY pg_total_relation_size(relid) DESC LIMIT 20) t) z
UNION ALL
SELECT 'S7_most_scanned', z.item, z.value, z.detail
FROM (SELECT t.schemaname || '.' || t.relname AS item,
             t.seq_tup_read::text || ' rows seq-scanned' AS value,
             'seq_scan=' || t.seq_scan || ' idx_scan=' || t.idx_scan ||
             ' size=' || pg_size_pretty(pg_total_relation_size(t.relid)) AS detail
      FROM (SELECT * FROM pg_stat_all_tables
            WHERE seq_scan > 0
              AND schemaname NOT IN ('pg_catalog', 'information_schema')
              AND schemaname NOT LIKE 'pg_toast%'
              AND schemaname NOT LIKE 'pg_temp%'
            ORDER BY seq_tup_read DESC LIMIT 20) t) z

UNION ALL
SELECT 'S8b_repl_slots', z.item, z.value, z.detail
FROM (SELECT s.slot_name AS item,
             s.slot_type || ' plugin=' || s.plugin || ' active=' || s.active AS value,
             'wal_status=' || s.wal_status ||
             ' safe_wal_size=' || pg_size_pretty(s.safe_wal_size) ||
             ' wal_pinned=' ||
             pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn)) AS detail
      FROM pg_replication_slots s ORDER BY s.slot_name) z
UNION ALL
SELECT 'S8_replication', r.application_name,
       'state=' || r.state || ' sync=' || r.sync_state,
       'write_lag=' || coalesce(r.write_lag::text, '-') ||
       ' replay_lag=' || coalesce(r.replay_lag::text, '-')
FROM pg_stat_replication r
UNION ALL
SELECT 'S8_subscriptions', sub.subname,
       'enabled=' || sub.subenabled || ' slot=' || coalesce(sub.subslotname, '-'),
       'publications=' ||
       (SELECT string_agg(p.pubname::text, ',')
        FROM pg_publication p WHERE p.pubname::text = ANY(sub.subpublications::text[]))
FROM pg_subscription sub
ORDER BY 1, 2;
