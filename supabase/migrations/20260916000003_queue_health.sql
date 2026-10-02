-- Observability for notification delivery (Phase 6).
-- Single RPC admins can poll + cron can log.

CREATE OR REPLACE FUNCTION public.get_notification_queue_health()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pending INT;
  v_processing INT;
  v_failed_1h INT;
  v_sent_1h INT;
  v_oldest_pending TIMESTAMPTZ;
  v_oldest_age_sec INT;
BEGIN
  SELECT COUNT(*) INTO v_pending FROM public.notification_queue WHERE status = 'pending';
  SELECT COUNT(*) INTO v_processing FROM public.notification_queue WHERE status = 'processing';
  SELECT COUNT(*) INTO v_failed_1h FROM public.notification_queue
    WHERE status = 'failed' AND updated_at >= NOW() - INTERVAL '1 hour';
  SELECT COUNT(*) INTO v_sent_1h FROM public.notification_queue
    WHERE status = 'sent' AND sent_at >= NOW() - INTERVAL '1 hour';
  SELECT MIN(created_at) INTO v_oldest_pending FROM public.notification_queue WHERE status = 'pending';
  IF v_oldest_pending IS NULL THEN
    v_oldest_age_sec := 0;
  ELSE
    v_oldest_age_sec := EXTRACT(EPOCH FROM (NOW() - v_oldest_pending))::INT;
  END IF;

  RETURN jsonb_build_object(
    'pending', COALESCE(v_pending, 0),
    'processing', COALESCE(v_processing, 0),
    'failed_last_hour', COALESCE(v_failed_1h, 0),
    'sent_last_hour', COALESCE(v_sent_1h, 0),
    'oldest_pending_at', v_oldest_pending,
    'oldest_pending_age_sec', v_oldest_age_sec,
    -- Alert when backlog grows or oldest waits too long (sender stuck).
    'alert', (COALESCE(v_pending, 0) > 1000 OR v_oldest_age_sec > 600 OR COALESCE(v_failed_1h, 0) > 50)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_notification_queue_health() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_notification_queue_health() TO authenticated;

COMMENT ON FUNCTION public.get_notification_queue_health()
  IS 'Queue health: pending/processing/failed/sent + alert flag (pending>1000 or oldest>10m or failed>50/h).';
