-- Grant SELECT on admin_broadcast_deliveries table to authenticated
-- This table is used for broadcast notifications

GRANT SELECT ON TABLE public.admin_broadcast_deliveries TO authenticated;

-- Verify permissions
SELECT
    table_name,
    privilege_type,
    grantee
FROM information_schema.table_privileges
WHERE table_schema = 'public'
    AND table_name = 'admin_broadcast_deliveries'
    AND privilege_type = 'SELECT'
ORDER BY grantee;