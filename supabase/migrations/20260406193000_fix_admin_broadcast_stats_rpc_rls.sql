BEGIN;

DROP FUNCTION IF EXISTS public.get_broadcast_stats(uuid);

CREATE OR REPLACE FUNCTION public.get_broadcast_stats(p_broadcast_id uuid)
RETURNS TABLE(
    total_target integer,
    sent_count integer,
    delivered_count integer,
    failed_count integer,
    delivery_rate numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL OR NOT EXISTS (
        SELECT 1
        FROM public.users u
        WHERE u.id = auth.uid()
          AND u.is_admin = true
    ) THEN
        RAISE EXCEPTION 'Admin access required'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        COUNT(*)::integer AS total_target,
        COUNT(*) FILTER (WHERE abd.delivery_status = 'sent')::integer AS sent_count,
        COUNT(*) FILTER (WHERE abd.delivery_status = 'delivered')::integer AS delivered_count,
        COUNT(*) FILTER (WHERE abd.delivery_status = 'failed')::integer AS failed_count,
        ROUND(
            (
                COUNT(*) FILTER (WHERE abd.delivery_status = 'delivered')::numeric /
                NULLIF(COUNT(*), 0) * 100
            ),
            2
        ) AS delivery_rate
    FROM public.admin_broadcast_deliveries abd
    WHERE abd.broadcast_id = p_broadcast_id;
END;
$$;

REVOKE ALL ON FUNCTION public.get_broadcast_stats(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_broadcast_stats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_broadcast_stats(uuid) TO service_role;

COMMIT;
