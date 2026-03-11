-- Check notification queue status
SELECT status, COUNT(*) as count 
FROM notification_queue 
GROUP BY status 
ORDER BY count DESC;

-- Check recent notifications
SELECT 
    fcm_token,
    title,
    body,
    status,
    attempts,
    created_at
FROM notification_queue 
ORDER BY created_at DESC 
LIMIT 10;