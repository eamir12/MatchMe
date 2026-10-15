-- System Health history: 7-day snapshot storage for the admin app.
-- A scheduled sampler (task inside the cron-jobs edge function, fired every
-- minute by pg_cron, rate-gated to ~5-minute cadence) inserts one row per
-- source (db, queue, statuspage, usage, auth, errors) per sample. The admin
-- app also inserts 'socket' rows on Realtime WebSocket state transitions
-- while an admin has the health screen open (RLS-limited insert).
-- Reads happen exclusively through the SECURITY DEFINER RPC below.
-- Safe to re-run.

CREATE TABLE IF NOT EXISTS public.admin_health_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  captured_at timestamptz NOT NULL DEFAULT now(),
  source text NOT NULL CHECK (
    source IN ('db', 'queue', 'statuspage', 'usage', 'auth', 'errors', 'socket')
  ),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  overall text
);

CREATE INDEX IF NOT EXISTS idx_admin_health_snapshots_source_captured_at
  ON public.admin_health_snapshots (source, captured_at DESC);

ALTER TABLE public.admin_health_snapshots ENABLE ROW LEVEL SECURITY;

-- Service role (the sampler) may write any source; no client select access.
DROP POLICY IF EXISTS service_role_all_admin_health_snapshots ON public.admin_health_snapshots;
CREATE POLICY service_role_all_admin_health_snapshots
  ON public.admin_health_snapshots
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Authenticated admins may record only socket transition events; they
-- cannot read the table (history goes through the admin RPC).
DROP POLICY IF EXISTS admin_insert_socket_events ON public.admin_health_snapshots;
CREATE POLICY admin_insert_socket_events
  ON public.admin_health_snapshots
  FOR INSERT
  TO authenticated
  WITH CHECK (
    source = 'socket'
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.is_admin = true
    )
  );

-- Retention: keep exactly 7 days. Called by the sampler after each write.
CREATE OR REPLACE FUNCTION public.prune_admin_health_snapshots()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM public.admin_health_snapshots
   WHERE captured_at < NOW() - INTERVAL '7 days';
$$;

GRANT EXECUTE ON FUNCTION public.prune_admin_health_snapshots() TO service_role;

-- History read for the admin app: per-source snapshot series for the
-- requested window, plus EXACT failure counts computed live from the
-- underlying tables (edge/cron/app error history already exists there,
-- so those numbers are precise, not sampled).
CREATE OR REPLACE FUNCTION public.admin_get_health_history(
  p_from timestamptz,
  p_to timestamptz DEFAULT NOW()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from timestamptz;
  v_to timestamptz;
  v_edge_failed int;
  v_edge_last timestamptz;
  v_edge_last_msg text;
  v_cron_failed int;
  v_latest_cron_tasks jsonb;
  v_cron_tasks jsonb := '[]'::jsonb;
  v_app_count int;
  v_app_last timestamptz;
  v_app_source text;
  v_app_message text;
  v_series jsonb := '{}'::jsonb;
  v_all jsonb := '{}'::jsonb;
  v_src text;
BEGIN
  IF auth.role() <> 'service_role' THEN
    IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true) THEN
      RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Clamp to the retention window and guard reversed ranges.
  v_to := LEAST(COALESCE(p_to, NOW()), NOW());
  v_from := GREATEST(
    COALESCE(p_from, NOW() - INTERVAL '24 hours'),
    NOW() - INTERVAL '7 days'
  );
  IF v_from >= v_to THEN
    v_from := v_to - INTERVAL '1 hour';
  END IF;

  -- Snapshot series, oldest first (chart order), one entry per source.
  FOR v_src IN
    SELECT unnest(ARRAY['db', 'queue', 'statuspage', 'usage', 'auth', 'errors', 'socket'])
  LOOP
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'at', s.captured_at,
          'overall', s.overall,
          'payload', s.payload
        )
        ORDER BY s.captured_at ASC
      ),
      '[]'::jsonb
    )
    INTO v_series
    FROM public.admin_health_snapshots s
    WHERE s.source = v_src
      AND s.captured_at >= v_from
      AND s.captured_at <= v_to;

    v_all := v_all || jsonb_build_object(v_src, v_series);
  END LOOP;

  -- Exact edge-function failure count in the chosen window (5xx only;
  -- 4xx rejections are correct behaviour; cron-jobs counted separately).
  SELECT COUNT(*), MAX(invoked_at)
    INTO v_edge_failed, v_edge_last
    FROM public.edge_function_invocations
   WHERE success = false
     AND (http_status IS NULL OR http_status >= 500)
     AND function_name <> 'cron-jobs'
     AND invoked_at >= v_from
     AND invoked_at <= v_to;

  SELECT LEFT(COALESCE(error_message, ''), 300)
    INTO v_edge_last_msg
    FROM public.edge_function_invocations
   WHERE success = false
     AND (http_status IS NULL OR http_status >= 500)
     AND function_name <> 'cron-jobs'
     AND invoked_at >= v_from
     AND invoked_at <= v_to
   ORDER BY invoked_at DESC
   LIMIT 1;

  -- Cron-jobs invocations that reported failed tasks in the window.
  SELECT COUNT(*)
    INTO v_cron_failed
    FROM public.edge_function_invocations
   WHERE function_name = 'cron-jobs'
     AND success = false
     AND invoked_at >= v_from
     AND invoked_at <= v_to;

  SELECT meta->'taskResults'
    INTO v_latest_cron_tasks
    FROM public.edge_function_invocations
   WHERE function_name = 'cron-jobs'
     AND success = false
     AND invoked_at >= v_from
     AND invoked_at <= v_to
   ORDER BY invoked_at DESC
   LIMIT 1;

  SELECT COALESCE(jsonb_agg(t->>'name'), '[]'::jsonb)
    INTO v_cron_tasks
    FROM jsonb_array_elements(COALESCE(v_latest_cron_tasks, '[]'::jsonb)) t
   WHERE (t->>'ok')::boolean IS DISTINCT FROM true;

  -- App-reported client errors in the window.
  SELECT COUNT(*), MAX(created_at)
    INTO v_app_count, v_app_last
    FROM public.app_error_log
   WHERE created_at >= v_from
     AND created_at <= v_to;

  SELECT source, LEFT(COALESCE(error_message, ''), 300)
    INTO v_app_source, v_app_message
    FROM public.app_error_log
   WHERE created_at >= v_from
     AND created_at <= v_to
   ORDER BY created_at DESC
   LIMIT 1;

  RETURN jsonb_build_object(
    'from', v_from,
    'to', v_to,
    'series', v_all,
    'errors', jsonb_build_object(
      'edge_failed', COALESCE(v_edge_failed, 0),
      'edge_last_failed_at', v_edge_last,
      'edge_last_error', v_edge_last_msg,
      'cron_failed_invocations', COALESCE(v_cron_failed, 0),
      'cron_last_failed_tasks', v_cron_tasks,
      'app_errors', COALESCE(v_app_count, 0),
      'app_last_error_at', v_app_last,
      'app_last_source', v_app_source,
      'app_last_message', v_app_message
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_health_history(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_health_history(timestamptz, timestamptz) TO service_role;
