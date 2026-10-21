-- Migration: index admin_health_snapshots(captured_at DESC).
--
-- WHY (measured 2026-10-21, pg_stat_statements + pg_stat_all_tables):
--
--   The only index on public.admin_health_snapshots is
--     idx_admin_health_snapshots_source_captured_at (source, captured_at DESC)
--   (20261026000000_admin_health_snapshots.sql:20)
--
--   But the two hot queries on this table filter on NOTHING and order by
--   captured_at alone:
--
--   1) supabase/functions/cron-jobs/health_sampler.ts:84-100 -- the gate
--      that runs on EVERY minute of the minutely cron-jobs edge function:
--        .from("admin_health_snapshots")
--        .select("captured_at")
--        .order("captured_at", { ascending: false })
--        .limit(1)
--        .maybeSingle()
--
--   2) public.prune_admin_health_snapshots() -- the retention delete:
--        DELETE FROM public.admin_health_snapshots
--         WHERE captured_at < NOW() - INTERVAL '7 days'
--
--   With 'source' as the index's leading column, the gate query cannot use
--   it. It falls back to a sequential scan of the whole table plus a sort:
--
--     Limit
--       -> Sort
--            Sort Key: captured_at DESC
--            -> Seq Scan on admin_health_snapshots
--
--   Measured cost of the gate:
--     3,645 calls, 16,784,995 rows seq-scanned (4,605 rows per call),
--     41 ms per call, 149,546 ms total CPU.
--   That is a full-table scan of a table that grows for 7 days, on every
--   minute of every day, to answer "what is the newest snapshot?".
--
--   With the new index that becomes:
--
--     Limit
--       -> Index Only Scan using idx_admin_health_snapshots_captured_at
--
--   The retention DELETE already found a usable path through the existing
--   (source, captured_at DESC) index -- a non-leading column can still be
--   used as an index qual -- so it was not seq-scanning. The new index
--   simply lets it use a single-purpose index instead of walking every
--   'source' group.
--
-- IMPACT: ~150 s/day of CPU and ~1,400 full table scans/day removed, and
-- the cost stops growing as the table fills toward its 7-day retention.
--
-- The existing (source, captured_at DESC) index is KEPT: it still serves
-- public.admin_get_health_history(), which reads per-source series.
--
-- NOT CONCURRENTLY: the table is ~1.7 MB, so a plain CREATE INDEX takes
-- milliseconds and the brief ACCESS EXCLUSIVE lock is harmless. It also
-- lets the migration run inside the usual transaction.

BEGIN;

CREATE INDEX IF NOT EXISTS idx_admin_health_snapshots_captured_at
  ON public.admin_health_snapshots (captured_at DESC);

-- Confirm both access paths can now use an index.
ANALYZE public.admin_health_snapshots;

EXPLAIN (COSTS OFF)
SELECT captured_at FROM public.admin_health_snapshots
ORDER BY captured_at DESC LIMIT 1;

EXPLAIN (COSTS OFF)
DELETE FROM public.admin_health_snapshots
WHERE captured_at < NOW() - INTERVAL '7 days';

COMMIT;
