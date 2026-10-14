-- Aggregated project-level failure counts for the admin System Health
-- screen: recent edge-function failures, cron task failures (with the
-- names of the failed tasks), and app-reported client errors.
-- Windows: 15 min for edge/app, 1 hour for cron. Safe to re-run.

CREATE INDEX IF NOT EXISTS idx_edge_function_invocations_failed_invoked_at
  ON public.edge_function_invocations (invoked_at)
  WHERE success = false;

CREATE OR REPLACE FUNCTION public.admin_get_health_errors()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_edge_failed int;
  v_edge_last timestamptz;
  v_edge_last_msg text;
  v_cron_failed int;
  v_cron_last timestamptz;
  v_latest_cron_tasks jsonb;
  v_cron_tasks jsonb := '[]'::jsonb;
  v_app_count int;
  v_app_last timestamptz;
  v_app_source text;
  v_app_message text;
BEGIN
  IF auth.role() <> 'service_role' THEN
    IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true) THEN
      RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Edge function failures, last 15 minutes. Only server-side faults
  -- count: 4xx rejections (wrong OTP, invalid input) are the function
  -- working correctly, and cron-jobs has its own counter below (it
  -- reports failed tasks with HTTP 200 + success=false).
  SELECT COUNT(*), MAX(invoked_at)
    INTO v_edge_failed, v_edge_last
    FROM public.edge_function_invocations
   WHERE success = false
     AND (http_status IS NULL OR http_status >= 500)
     AND function_name <> 'cron-jobs'
     AND invoked_at >= NOW() - INTERVAL '15 minutes';

  SELECT LEFT(COALESCE(error_message, ''), 300)
    INTO v_edge_last_msg
    FROM public.edge_function_invocations
   WHERE success = false
     AND (http_status IS NULL OR http_status >= 500)
     AND function_name <> 'cron-jobs'
     AND invoked_at >= NOW() - INTERVAL '15 minutes'
   ORDER BY invoked_at DESC
   LIMIT 1;

  -- Cron-jobs failures, last 1 hour (its invocation row carries
  -- meta.taskResults = [{name, ok, errorMessage, errorCode} ...]).
  SELECT COUNT(*), MAX(invoked_at)
    INTO v_cron_failed, v_cron_last
    FROM public.edge_function_invocations
   WHERE function_name = 'cron-jobs'
     AND success = false
     AND invoked_at >= NOW() - INTERVAL '1 hour';

  SELECT meta->'taskResults'
    INTO v_latest_cron_tasks
    FROM public.edge_function_invocations
   WHERE function_name = 'cron-jobs'
     AND success = false
     AND invoked_at >= NOW() - INTERVAL '1 hour'
   ORDER BY invoked_at DESC
   LIMIT 1;

  SELECT COALESCE(jsonb_agg(t->>'name'), '[]'::jsonb)
    INTO v_cron_tasks
    FROM jsonb_array_elements(COALESCE(v_latest_cron_tasks, '[]'::jsonb)) t
   WHERE (t->>'ok')::boolean IS DISTINCT FROM true;

  -- App-reported errors, last 15 minutes.
  SELECT COUNT(*), MAX(created_at)
    INTO v_app_count, v_app_last
    FROM public.app_error_log
   WHERE created_at >= NOW() - INTERVAL '15 minutes';

  SELECT source, LEFT(COALESCE(error_message, ''), 300)
    INTO v_app_source, v_app_message
    FROM public.app_error_log
   WHERE created_at >= NOW() - INTERVAL '15 minutes'
   ORDER BY created_at DESC
   LIMIT 1;

  RETURN jsonb_build_object(
    'checked_at', NOW(),
    'edge_failed_15m', COALESCE(v_edge_failed, 0),
    'edge_last_failed_at', v_edge_last,
    'edge_last_error', v_edge_last_msg,
    'cron_failed_1h', COALESCE(v_cron_failed, 0),
    'cron_last_failed_at', v_cron_last,
    'cron_last_failed_tasks', v_cron_tasks,
    'app_errors_15m', COALESCE(v_app_count, 0),
    'app_last_error_at', v_app_last,
    'app_last_source', v_app_source,
    'app_last_message', v_app_message
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_health_errors() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_health_errors() TO service_role;
