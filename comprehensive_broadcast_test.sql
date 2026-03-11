-- Comprehensive Admin Broadcast System Test Script
-- This script tests all 7 filtering options with sample data like the user provided

-- First, let's create some test users with various attributes
-- These match the sample data format you provided

-- Insert test users (if they don't already exist)
INSERT INTO users (id, email, gender, subscription_tier, verification_status, date_of_birth, system_visibility_status, is_admin)
VALUES 
    -- Female, platinum, unverified, 18 years old
    ('35fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, 'eranamir12@gmail.com', 'female', 'platinum', 'unverified', CURRENT_DATE - INTERVAL '18 years', 'visible', false),
    
    -- Male, gold, verified, 20 years old  
    ('45fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, 'test.male20@example.com', 'male', 'gold', 'approved', CURRENT_DATE - INTERVAL '20 years', 'visible', false),
    
    -- Female, silver, unverified, 25 years old
    ('55fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, 'test.female25@example.com', 'female', 'silver', 'unverified', CURRENT_DATE - INTERVAL '25 years', 'invisible', false),
    
    -- Male, platinum, approved, 19 years old
    ('65fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, 'test.male19@example.com', 'male', 'platinum', 'approved', CURRENT_DATE - INTERVAL '19 years', 'visible', false),
    
    -- Female, bronze, rejected, 22 years old
    ('75fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, 'test.female22@example.com', 'female', 'bronze', 'rejected', CURRENT_DATE - INTERVAL '22 years', 'visible', false)
ON CONFLICT (id) DO NOTHING;

-- Create test user sessions with FCM tokens
INSERT INTO user_session (id, user_id, platform, metadata, last_active_at, revoked)
VALUES 
    ('35fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, '35fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, 'android', '{"fcm_token": "test_token_1"}', NOW(), false),
    ('45fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, '45fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, 'ios', '{"fcm_token": "test_token_2"}', NOW(), false),
    ('55fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, '55fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, 'android', '{"fcm_token": "test_token_3"}', NOW(), false),
    ('65fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, '65fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, 'ios', '{"fcm_token": "test_token_4"}', NOW(), false),
    ('75fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, '75fe114e-eae5-49d6-9eba-8459617e7b82'::uuid, 'android', '{"fcm_token": "test_token_5"}', NOW(), false)
ON CONFLICT (id) DO NOTHING;

-- Create an admin user for testing broadcasts
INSERT INTO users (id, email, is_admin, system_visibility_status)
VALUES ('admin-test-id'::uuid, 'admin@test.com', true, 'visible')
ON CONFLICT (id) DO NOTHING;

-- =====================================================
-- TEST ALL 7 FILTERING OPTIONS
-- =====================================================

-- 1. All users
SELECT '=== TEST 1: All Users ===' as test_name;
SELECT u.id, u.email, u.gender, u.subscription_tier, u.verification_status,
       EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) as age,
       u.system_visibility_status
FROM get_users_for_broadcast('{"all_users": true}'::jsonb) f
JOIN users u ON u.id = f.user_id
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
-- CREATE SAMPLE BROADCASTS
-- =====================================================

-- Create a broadcast targeting the sample user (like your provided data)
INSERT INTO admin_broadcasts (
    title, 
    message, 
    message_type, 
    scheduled_at, 
    filter_criteria, 
    action_url,
    action_text,
    created_by
) VALUES 
(
    'Special Offer for Young Female Platinum Users',
    'Hey! As a young female platinum member, you get exclusive access to premium features. Tap to learn more!',
    'promotion',
    NOW(),
    '{"gender": ["female"], "subscription_tiers": ["platinum"], "age_range": {"min": 18, "max": 21}, "verification_status": ["unverified"], "visible_only": true}',
    'https://matchme.example.com/premium-offer',
    'Claim Your Offer',
    'admin-test-id'::uuid
),
(
    'Welcome to All New Users',
    'Welcome to MatchMe! Complete your profile to get started.',
    'welcome',
    NOW(),
    '{"all_users": true}',
    'https://matchme.example.com/profile-setup',
    'Complete Profile',
    'admin-test-id'::uuid
),
(
    'Gold Members Exclusive',
    'Gold members get priority matching and unlimited swipes!',
    'info',
    NOW() + INTERVAL '1 hour',
    '{"subscription_tiers": ["gold"]}',
    'https://matchme.example.com/gold-benefits',
    'Upgrade Now',
    'admin-test-id'::uuid
);

-- Show the created broadcasts
SELECT '=== CREATED BROADCASTS ===' as info;
SELECT id, title, message, message_type, scheduled_at, 
       filter_criteria->>'gender' as gender_filter,
       filter_criteria->>'subscription_tiers' as tier_filter,
       filter_criteria->>'age_range' as age_filter,
       filter_criteria->>'verification_status' as verification_filter,
       (filter_criteria->>'visible_only')::boolean as visible_only,
       action_url,
       action_text
FROM admin_broadcasts 
ORDER BY created_at DESC;

-- Show target user counts for each broadcast
SELECT '=== TARGET USER COUNTS ===' as info;
SELECT 
    b.id,
    b.title,
    COUNT(*) as target_user_count
FROM admin_broadcasts b
CROSS JOIN get_users_for_broadcast(b.filter_criteria) f
GROUP BY b.id, b.title
ORDER BY b.created_at DESC;

-- Show detailed breakdown for the complex filter broadcast
SELECT '=== DETAILED BREAKDOWN: Complex Filter Broadcast ===' as info;
SELECT 
    u.id,
    u.email,
    u.gender,
    u.subscription_tier,
    u.verification_status,
    EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) as age,
    u.system_visibility_status,
    f.fcm_token,
    f.platform
FROM admin_broadcasts b
CROSS JOIN get_users_for_broadcast(b.filter_criteria) f
JOIN users u ON u.id = f.user_id
WHERE b.title = 'Special Offer for Young Female Platinum Users'
ORDER BY u.email;

-- =====================================================
-- TEST BROADCAST DELIVERY TRACKING
-- =====================================================

-- Simulate sending the broadcast (this would normally be done by the scheduled job)
SELECT send_admin_broadcast((SELECT id FROM admin_broadcasts WHERE title = 'Special Offer for Young Female Platinum Users' LIMIT 1));

-- Check delivery tracking
SELECT '=== BROADCAST DELIVERY TRACKING ===' as info;
SELECT 
    b.title,
    d.user_id,
    u.email,
    d.status,
    d.sent_at,
    d.delivered_at,
    d.error_message
FROM admin_broadcast_delivery d
JOIN admin_broadcasts b ON b.id = d.broadcast_id
JOIN users u ON u.id = d.user_id
ORDER BY d.sent_at DESC;