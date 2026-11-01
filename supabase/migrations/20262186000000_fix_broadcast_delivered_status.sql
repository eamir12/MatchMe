-- Migration: delivered receipts count as a successful broadcast outcome,
-- and send_admin_broadcast keeps service_role-only execute.
--
-- 1) send_admin_broadcast() recomputes admin_broadcasts.status from the
--    delivery ledger on every dispatch pass. The status CASE counted only
--    pending/queued/sent, but the device receipt flips a sent row to
--    'delivered'. With instant dispatch the receipt arrives before the next
--    pass, so the recompute saw zero successes and mislabelled a delivered
--    broadcast 'cancelled' with actual_sent_count 0. Delivered is a terminal
--    success and must count.
--
-- 2) The DROP/CREATE in 20262184000000 reset this function's ACL, leaving the
--    default PUBLIC EXECUTE (anon + authenticated). Only cron-jobs (service
--    role) may call it. Same follow-up for get_notification_queue_health,
--    which keeps authenticated because the admin health monitor uses it.

BEGIN;

DROP FUNCTION IF EXISTS public.send_admin_broadcast(uuid, integer, integer);

CREATE OR REPLACE FUNCTION public.send_admin_broadcast(
  p_broadcast_id UUID,
  p_limit INT DEFAULT 20000,
  p_offset INT DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  broadcast_record public.admin_broadcasts%ROWTYPE;
  target_delivery RECORD;
  c JSONB;
  v_issues TEXT[];
  v_limit INT;
  v_freq_limit INT;
  v_sent INT := 0;
  v_delivered INT := 0;
  v_queued INT := 0;
  v_failed INT := 0;
  v_skipped INT := 0;
  v_pending INT := 0;
  v_total INT := 0;
  v_processed INT := 0;
BEGIN
  -- Serialise concurrent invocations for the same broadcast.
  SELECT * INTO broadcast_record
  FROM public.admin_broadcasts
  WHERE id = p_broadcast_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Broadcast not found';
  END IF;

  v_issues := public.check_notification_limits(
    broadcast_record.title, broadcast_record.message,
    broadcast_record.action_url, broadcast_record.action_url_text
  );
  IF array_length(v_issues, 1) > 0 THEN
    UPDATE public.admin_broadcasts
    SET status = 'failed', updated_at = NOW()
    WHERE id = p_broadcast_id;
    RETURN jsonb_build_object('success', false, 'errors', to_jsonb(v_issues));
  END IF;

  v_limit := GREATEST(LEAST(COALESCE(p_limit, 20000), 20000), 1);
  v_freq_limit := GREATEST(
    public.app_config_int('notifications.admin_broadcast_max_per_day', 10), 1
  );
  c := public.normalize_broadcast_filter_criteria(broadcast_record.filter_criteria);

  IF broadcast_record.status IN ('draft', 'scheduled', 'failed') THEN
    UPDATE public.admin_broadcasts
    SET status = 'sending',
        sent_at = NOW(),
        filter_criteria = c,
        skipped_count = 0,
        updated_at = NOW()
    WHERE id = p_broadcast_id;
  END IF;

  -- Snapshot the audience exactly once. DISTINCT ON collapses users with
  -- several live sessions to one push; ON CONFLICT makes a re-entry a no-op.
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_broadcast_deliveries d
    WHERE d.broadcast_id = p_broadcast_id
      AND d.delivery_key = 'once'
  ) THEN
    INSERT INTO public.admin_broadcast_deliveries (
      broadcast_id, user_id, fcm_token, platform, delivery_status, delivery_key
    )
    SELECT p_broadcast_id, g.user_id, g.fcm_token, g.platform, 'pending', 'once'
    FROM (
      SELECT DISTINCT ON (gu.user_id)
        gu.user_id, gu.fcm_token, gu.platform
      FROM public.get_users_for_broadcast(c) gu
      ORDER BY gu.user_id, gu.fcm_token
    ) g
    ON CONFLICT (broadcast_id, user_id, delivery_key) DO NOTHING;
  END IF;

  FOR target_delivery IN
    SELECT d.id, d.user_id, d.fcm_token, d.platform
    FROM public.admin_broadcast_deliveries d
    WHERE d.broadcast_id = p_broadcast_id
      AND d.delivery_key = 'once'
      AND d.delivery_status = 'pending'
    ORDER BY d.id
    LIMIT v_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_processed := v_processed + 1;

    IF (
      SELECT COUNT(*) FROM public.notification_queue q
      WHERE q.user_id = target_delivery.user_id
        AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) >= v_freq_limit THEN
      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'skipped', failure_reason = 'frequency_guard'
      WHERE id = target_delivery.id;
      CONTINUE;
    END IF;

    BEGIN
      PERFORM public.queue_fcm_notification(
        target_delivery.user_id,
        target_delivery.fcm_token,
        broadcast_record.title,
        broadcast_record.message,
        jsonb_build_object(
          'type', 'admin_broadcast',
          'broadcast_id', p_broadcast_id,
          'delivery_key', 'once',
          'action_url', broadcast_record.action_url,
          'action_url_text', broadcast_record.action_url_text
        ),
        target_delivery.platform
      );

      -- The push is only queued here. The drainer flips this to 'sent' when
      -- FCM accepts the message (or 'failed' on a definitive rejection).
      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'queued',
          sent_at = NULL,
          failure_reason = NULL
      WHERE id = target_delivery.id;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'failed',
          failure_reason = left(SQLERRM, 500)
      WHERE id = target_delivery.id;
    END;
  END LOOP;

  -- 'delivered' is the device receipt for a 'sent' row: both are successes.
  SELECT
    count(*) FILTER (WHERE delivery_status = 'sent'),
    count(*) FILTER (WHERE delivery_status = 'delivered'),
    count(*) FILTER (WHERE delivery_status = 'failed'),
    count(*) FILTER (WHERE delivery_status = 'skipped'),
    count(*) FILTER (WHERE delivery_status = 'pending'),
    count(*) FILTER (WHERE delivery_status = 'queued'),
    count(*)
  INTO v_sent, v_delivered, v_failed, v_skipped, v_pending, v_queued, v_total
  FROM public.admin_broadcast_deliveries d
  WHERE d.broadcast_id = p_broadcast_id
    AND d.delivery_key = 'once';

  UPDATE public.admin_broadcasts
  SET target_user_count = v_total,
      actual_sent_count = v_sent + v_delivered + v_queued,
      skipped_count = v_skipped,
      status = CASE
        WHEN v_pending = 0 AND v_queued = 0 AND v_sent = 0 AND v_delivered = 0 THEN 'cancelled'
        WHEN v_pending = 0 AND v_queued = 0 THEN 'sent'
        ELSE 'sending'
      END,
      updated_at = NOW()
  WHERE id = p_broadcast_id;

  RETURN jsonb_build_object(
    'success', true,
    'complete', v_pending = 0 AND v_queued = 0,
    'processed_count', v_processed,
    'sent_count', v_sent,
    'delivered_count', v_delivered,
    'queued_count', v_queued,
    'failed_count', v_failed,
    'skipped_count', v_skipped,
    'pending_count', v_pending,
    'recipient_total', v_total
  );
END;
$$;

REVOKE ALL ON FUNCTION public.send_admin_broadcast(uuid, integer, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.send_admin_broadcast(uuid, integer, integer)
  TO service_role;

-- Keep authenticated for the admin health monitor; drop the stray PUBLIC.
REVOKE ALL ON FUNCTION public.get_notification_queue_health() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_notification_queue_health()
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
