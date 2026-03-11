-- Check current notification queue status
SELECT 
    status,
    COUNT(*) as count,
    MIN(created_at) as oldest,
    MAX(created_at) as newest
FROM notification_queue 
GROUP BY status 
ORDER BY count DESC;

-- Check specific notifications
SELECT 
    fcm_token,
    title,
    body,
    status,
    attempts,
    failure_reason,
    created_at
FROM notification_queue 
WHERE status != 'sent'
ORDER BY created_at DESC 
LIMIT 5;