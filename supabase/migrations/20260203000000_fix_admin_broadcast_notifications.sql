BEGIN;

ALTER TABLE IF EXISTS notification_queue ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "service_role can manage notification_queue" ON notification_queue;
CREATE POLICY "service_role can manage notification_queue"
ON notification_queue
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

REVOKE ALL ON TABLE notification_queue FROM anon;
REVOKE ALL ON TABLE notification_queue FROM authenticated;
GRANT ALL ON TABLE notification_queue TO service_role;

REVOKE EXECUTE ON FUNCTION queue_fcm_notification(UUID, TEXT, TEXT, TEXT, JSONB, TEXT) FROM authenticated;
REVOKE EXECUTE ON FUNCTION send_admin_broadcast(UUID) FROM authenticated;
REVOKE EXECUTE ON FUNCTION process_notification_queue() FROM authenticated;

GRANT EXECUTE ON FUNCTION queue_fcm_notification(UUID, TEXT, TEXT, TEXT, JSONB, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION send_admin_broadcast(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION process_notification_queue() TO service_role;

DROP POLICY IF EXISTS "Users can update own deliveries" ON admin_broadcast_deliveries;
CREATE POLICY "Users can update own deliveries"
ON admin_broadcast_deliveries
FOR UPDATE
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

DROP FUNCTION IF EXISTS mark_broadcast_failed(UUID, TEXT);
CREATE OR REPLACE FUNCTION mark_broadcast_failed(p_broadcast_id UUID, p_failure_reason TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE admin_broadcasts
    SET status = 'failed', updated_at = NOW()
    WHERE id = p_broadcast_id;

    UPDATE admin_broadcast_deliveries
    SET delivery_status = 'failed', failure_reason = p_failure_reason
    WHERE broadcast_id = p_broadcast_id AND delivery_status = 'pending';
END;
$$ LANGUAGE plpgsql;

DROP FUNCTION IF EXISTS get_broadcast_stats(UUID);
CREATE OR REPLACE FUNCTION get_broadcast_stats(p_broadcast_id UUID)
RETURNS TABLE(
    total_target INTEGER,
    sent_count INTEGER,
    delivered_count INTEGER,
    failed_count INTEGER,
    delivery_rate NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        COUNT(*)::INTEGER as total_target,
        COUNT(*) FILTER (WHERE delivery_status = 'sent')::INTEGER as sent_count,
        COUNT(*) FILTER (WHERE delivery_status = 'delivered')::INTEGER as delivered_count,
        COUNT(*) FILTER (WHERE delivery_status = 'failed')::INTEGER as failed_count,
        ROUND(
            (COUNT(*) FILTER (WHERE delivery_status = 'delivered')::NUMERIC /
             NULLIF(COUNT(*), 0) * 100), 2
        ) as delivery_rate
    FROM admin_broadcast_deliveries
    WHERE broadcast_id = p_broadcast_id;
END;
$$ LANGUAGE plpgsql;

COMMIT;
