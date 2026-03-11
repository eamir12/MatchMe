-- Fixed Admin Broadcast System Test Script
-- This version fixes the foreign key constraint issue by using existing users or proper auth flow

-- =====================================================
-- STEP 1: Get existing valid user IDs from auth.users
-- =====================================================

-- First, let's see what users we have available
SELECT '=== EXISTING USERS IN AUTH SYSTEM ===' as info;
SELECT id, email FROM auth.users LIMIT 5;

-- Check existing users in our users table
SELECT '=== EXISTING USERS IN PUBLIC USERS TABLE ===' as info;
SELECT id, email, gender, subscription_tier, verification_status, system_visibility_status, is_admin
FROM users 
LIMIT 5;

-- If we don't have enough test users, let's create some using proper auth flow
-- For now, let's work with existing users and create test sessions

-- =====================================================
-- STEP 2: Create test user sessions with FCM tokens for existing users
-- =====================================================

-- Get some existing user IDs to work with
WITH existing_users AS (
    SELECT id FROM users WHERE system_visibility_status = 'visible' LIMIT 3
)
INSERT INTO user_session (id, user_id, platform, metadata, last_active_at, revoked)
SELECT 
    gen_random_uuid(),
    u.id,
    CASE WHEN random() < 0.5 THEN 'android' ELSE 'ios' END,
    jsonb_build_object('fcm_token', 'test_token_' || substr(md5(random()::text), 1, 8)),
    NOW() - INTERVAL '1 hour' * (random() * 24)::int,
    false
FROM existing_users u
ON CONFLICT (id) DO NOTHING;

-- Show what we created
SELECT '=== CREATED TEST SESSIONS ===' as info;
SELECT 
    us.id as session_id,
    us.user_id,
    u.email,
    us.platform,
    us.metadata->>'fcm_token' as fcm_token,
    us.last_active_at,
    u.system_visibility_status
FROM user_session us
JOIN users u ON u.id = us.user_id
WHERE us.metadata->>'fcm_token' LIKE 'test_token_%'
ORDER BY us.created_at DESC;

-- =====================================================
-- STEP 3: Test all 7 filtering options with existing users
-- =====================================================

-- 1. All users with sessions
SELECT '=== TEST 1: All Users with Active Sessions ===' as test_name;
SELECT u.id, u.email, u.gender, u.subscription_tier, u.verification_status,
       EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) as age,
       u.system_visibility_status,
       us.platform
FROM get_users_for_broadcast('{"all_users": true}'::jsonb) f
JOIN users u ON u.id = f.user_id
JOIN user_session us ON us.user_id = u.id AND us.metadata->>'fcm_token' LIKE 'test_token_%'
ORDER BY u.email;

-- 2. All female users  
SELECT '=== TEST 2: All Female Users ===' as test_name;
SELECT u.id, u.email, u.gender, u.subscription_tier, u.verification_status,
       EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) as age,
       u.system_visibility_status
FROM get_users_for_broadcast('{"gender": ["female"]}'::jsonb) f
JOIN users u ON u.id = f.user_id
ORDER BY u.email;

-- 3. All users between ages 18 and 21 years old
SELECT '=== TEST 3: Users Aged 18-21 ===' as test_name;
SELECT u.id, u.email, u.gender, u.subscription_tier, u.verification_status,
       EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) as age,
       u.system_visibility_status
FROM get_users_for_broadcast('{"age_range": {"min": 18, "max": 21}}'::jsonb) f
JOIN users u ON u.id = f.user_id
ORDER BY u.email;

-- 4. All users in the Gold tier
SELECT '=== TEST 4: Gold Tier Users ===' as test_name;
SELECT u.id, u.email, u.gender, u.subscription_tier, u.verification_status,
       EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) as age,
       u.system_visibility_status
FROM get_users_for_broadcast('{"subscription_tiers": ["gold"]}'::jsonb) f
JOIN users u ON u.id = f.user_id
ORDER BY u.email;

-- 5. All users that have not verified their profile photo (unverified status)
SELECT '=== TEST 5: Unverified Users ===' as test_name;
SELECT u.id, u.email, u.gender, u.subscription_tier, u.verification_status,
       EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) as age,
       u.system_visibility_status
FROM get_users_for_broadcast('{"verification_status": ["unverified"]}'::jsonb) f
JOIN users u ON u.id = f.user_id
ORDER BY u.email;

-- 6. All currently visible users
SELECT '=== TEST 6: Currently Visible Users ===' as test_name;
SELECT u.id, u.email, u.gender, u.subscription_tier, u.verification_status,
       EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) as age,
       u.system_visibility_status
FROM get_users_for_broadcast('{"visible_only": true}'::jsonb) f
JOIN users u ON u.id = f.user_id
ORDER BY u.email;

-- 7. Any combination of the above (Female, Platinum, Unverified, Aged 18-21, Visible)
SELECT '=== TEST 7: Combined Filters ===' as test_name;
SELECT u.id, u.email, u.gender, u.subscription_tier, u.verification_status,
       EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) as age,
       u.system_visibility_status
FROM get_users_for_broadcast('{
  "gender": ["female"],
  "subscription_tiers": ["platinum"], 
  "verification_status": ["unverified"],
  "age_range": {"min": 18, "max": 21},
  "visible_only": true
}'::jsonb) f
JOIN users u ON u.id = f.user_id
ORDER BY u.email;

-- =====================================================
-- STEP 4: Create sample broadcasts targeting existing users
-- =====================================================

-- Find an admin user or create one
INSERT INTO users (id, email, is_admin, system_visibility_status, gender, subscription_tier, verification_status, date_of_birth)
SELECT 
    '00000000-0000-0000-0000-000000000001'::uuid,
    'admin@test.local',
    true,
    'visible',
    'male',
    'platinum',
    'approved',
    CURRENT_DATE - INTERVAL '30 years'
WHERE NOT EXISTS (SELECT 1 FROM users WHERE is_admin = true)
ON CONFLICT (id) DO NOTHING;

-- Create test broadcasts
INSERT INTO admin_broadcasts (
    title, 
    message, 
    message_type, 
    scheduled_at, 
    filter_criteria, 
    action_url,
    action_url_text,
    created_by
) VALUES 
(
    'Welcome New Users!',
    'Thanks for joining MatchMe! Complete your profile to get started.',
    'info',
    NOW(),
    '{"all_users": true}',
    'https://matchme.example.com/profile-setup',
    'Complete Profile',
    (SELECT id FROM users WHERE is_admin = true LIMIT 1)
),
(
    'Special Offer for Young Female Users',
    'Hey! As a young female member, you get exclusive access to premium features.',
    'promotion',
    NOW(),
    '{"gender": ["female"], "age_range": {"min": 18, "max": 25}, "visible_only": true}',
    'https://matchme.example.com/premium-offer',
    'Claim Offer',
    (SELECT id FROM users WHERE is_admin = true LIMIT 1)
),
(
    'Gold Members Exclusive',
    'Gold members get priority matching and unlimited swipes!',
    'info',
    NOW() + INTERVAL '1 hour',
    '{"subscription_tiers": ["gold"], "visible_only": true}',
    'https://matchme.example.com/gold-benefits',
    'Upgrade Now',
    (SELECT id FROM users WHERE is_admin = true LIMIT 1)
);

-- Show the created broadcasts
SELECT '=== CREATED BROADCASTS ===' as info;
SELECT id, title, message, message_type, scheduled_at, 
       filter_criteria->>'gender' as gender_filter,
       filter_criteria->>'subscription_tiers' as tier_filter,
       filter_criteria->>'age_range' as age_filter,
       (filter_criteria->>'visible_only')::boolean as visible_only,
       action_url,
       action_url_text
FROM admin_broadcasts 
WHERE created_at > NOW() - INTERVAL '5 minutes'
ORDER BY created_at DESC;

-- Show target user counts for each broadcast
SELECT '=== TARGET USER COUNTS ===' as info;
SELECT 
    b.id,
    b.title,
    COUNT(*) as target_user_count
FROM admin_broadcasts b
CROSS JOIN get_users_for_broadcast(b.filter_criteria) f
WHERE b.created_at > NOW() - INTERVAL '5 minutes'
GROUP BY b.id, b.title
ORDER BY b.created_at DESC;

-- =====================================================
-- STEP 5: Test broadcast delivery
-- =====================================================

-- Test sending one of the broadcasts
SELECT '=== TESTING BROADCAST DELIVERY ===' as info;
SELECT send_admin_broadcast((SELECT id FROM admin_broadcasts WHERE title = 'Welcome New Users!' LIMIT 1));

-- Check delivery results
SELECT 
    b.title,
    d.user_id,
    u.email,
    d.delivery_status,
    d.created_at as sent_at,
    d.delivered_at,
    d.failure_reason as error_message
FROM admin_broadcast_deliveries d
JOIN admin_broadcasts b ON b.id = d.broadcast_id
JOIN users u ON u.id = d.user_id
WHERE b.title = 'Welcome New Users!'
ORDER BY d.created_at DESC;

-- Show final summary
SELECT '=== TEST SUMMARY ===' as info;
SELECT 
    'Total test users with sessions' as metric,
    COUNT(*) as value
FROM user_session us
JOIN users u ON u.id = us.user_id
WHERE us.metadata->>'fcm_token' LIKE 'test_token_%';

SELECT 
    'Total broadcasts created' as metric,
    COUNT(*) as value
FROM admin_broadcasts 
WHERE created_at > NOW() - INTERVAL '5 minutes';

SELECT 
    'Total deliveries attempted' as metric,
    COUNT(*) as value
FROM admin_broadcast_deliveries d
JOIN admin_broadcasts b ON b.id = d.broadcast_id
WHERE b.created_at > NOW() - INTERVAL '5 minutes';