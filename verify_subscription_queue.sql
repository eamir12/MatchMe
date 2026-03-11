
-- Simplified verification queries (compatible with all pg_cron versions)

-- 1. Check if the cron job exists
SELECT 
    jobid,
    jobname,
    schedule,
    active
FROM cron.job
WHERE jobname = 'subscription-normalization';

-- 2. List all cron jobs
SELECT * FROM cron.job;

-- 3. Check pg_cron extension is enabled
SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_cron';

-- 4. View the subscription queue table structure
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'user_subscription_queue'
ORDER BY ordinal_position;

-- 5. Test the add_subscription_to_queue function
-- (Uncomment and replace with your user_id to test)
-- SELECT * FROM add_subscription_to_queue(
--     'YOUR_USER_ID_HERE'::UUID,
--     'platinum',
--     2592000,  -- 30 days in seconds
--     'manual',
--     'test-transaction-123',
--     '{"test": true}'::jsonb
-- );

-- 6. View a user's subscription queue
-- (Uncomment and replace with your user_id)
-- SELECT 
--     id,
--     tier,
--     status,
--     starts_at,
--     expires_at,
--     payment_provider,
--     created_at
-- FROM user_subscription_queue
-- WHERE user_id = 'YOUR_USER_ID_HERE'
-- ORDER BY starts_at;

-- 7. View user's subscription timeline
-- (Uncomment and replace with your user_id)
-- SELECT * FROM get_user_subscription_timeline('YOUR_USER_ID_HERE');

-- 8. Test normalization manually
-- SELECT trigger_subscription_normalization();

-- 9. Check a specific user's subscription status
-- (Uncomment and replace with your user_id)
-- SELECT * FROM check_and_normalize_user_subscription('YOUR_USER_ID_HERE');

-- 10. Count subscriptions by status
SELECT 
    status,
    COUNT(*) as count
FROM user_subscription_queue
GROUP BY status;

-- 11. Find expired subscriptions with pending queue
SELECT 
    u.id as user_id,
    u.subscription_tier as current_tier,
    u.subscription_expires_at as expires_at,
    sq.tier as queued_tier,
    sq.starts_at as queued_starts_at
FROM users u
JOIN user_subscription_queue sq ON sq.user_id = u.id
WHERE u.subscription_expires_at <= NOW()
    AND u.subscription_tier IS NOT NULL
    AND u.subscription_tier != 'free'
    AND sq.status = 'pending'
    AND sq.starts_at <= NOW()
ORDER BY u.subscription_expires_at;

-- 12. Test adding multiple subscriptions to queue (simulates user buying 3 tiers)
-- (Uncomment to test)
-- DO $$
-- DECLARE
--     v_user_id UUID := 'YOUR_USER_ID_HERE'::UUID;
-- BEGIN
--     -- Add Gold (30 days)
--     PERFORM add_subscription_to_queue(v_user_id, 'gold', 2592000, 'manual', 'test-1', '{}');
--     -- Add Plus (7 days, will queue after Gold)
--     PERFORM add_subscription_to_queue(v_user_id, 'plus', 604800, 'manual', 'test-2', '{}');
--     -- Add Platinum (30 days, will queue after Plus)
--     PERFORM add_subscription_to_queue(v_user_id, 'platinum', 2592000, 'manual', 'test-3', '{}');
-- END $$;
