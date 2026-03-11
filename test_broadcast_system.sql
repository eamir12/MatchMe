-- Test the admin broadcast system with various filtering options
-- This file contains test queries to verify the broadcast functionality

-- Test 1: Create a test broadcast for all users
INSERT INTO admin_broadcasts (title, message, message_type, scheduled_at, filter_criteria, created_by)
VALUES 
('Test Broadcast - All Users', 'This is a test message for all users', 'info', NOW(), '{"all_users": true}', (SELECT id FROM users WHERE is_admin = true LIMIT 1));

-- Test 2: Create a test broadcast for female users only
INSERT INTO admin_broadcasts (title, message, message_type, scheduled_at, filter_criteria, created_by)
VALUES 
('Test Broadcast - Female Users', 'This is a test message for female users', 'info', NOW(), '{"gender": ["female"]}', (SELECT id FROM users WHERE is_admin = true LIMIT 1));

-- Test 3: Create a test broadcast for users aged 18-21
INSERT INTO admin_broadcasts (title, message, message_type, scheduled_at, filter_criteria, created_by)
VALUES 
('Test Broadcast - Age 18-21', 'This is a test message for users aged 18-21', 'info', NOW(), '{"age_range": {"min": 18, "max": 21}}', (SELECT id FROM users WHERE is_admin = true LIMIT 1));

-- Test 4: Create a test broadcast for Gold tier users
INSERT INTO admin_broadcasts (title, message, message_type, scheduled_at, filter_criteria, created_by)
VALUES 
('Test Broadcast - Gold Tier', 'This is a test message for Gold tier users', 'info', NOW(), '{"subscription_tiers": ["gold"]}', (SELECT id FROM users WHERE is_admin = true LIMIT 1));

-- Test 5: Create a test broadcast for unverified users
INSERT INTO admin_broadcasts (title, message, message_type, scheduled_at, filter_criteria, created_by)
VALUES 
('Test Broadcast - Unverified Users', 'This is a test message for unverified users', 'info', NOW(), '{"verification_status": ["unverified"]}', (SELECT id FROM users WHERE is_admin = true LIMIT 1));

-- Test 6: Create a test broadcast with clickable URL
INSERT INTO admin_broadcasts (title, message, message_type, scheduled_at, filter_criteria, action_url, action_url_text, created_by)
VALUES 
('Test Broadcast - With URL', 'Check out our new features!', 'info', NOW(), '{"all_users": true}', 'https://matchme.app/features', 'View Features', (SELECT id FROM users WHERE is_admin = true LIMIT 1));

-- Test 7: Create a test broadcast with combined filters (female, Gold tier, aged 18-25)
INSERT INTO admin_broadcasts (title, message, message_type, scheduled_at, filter_criteria, created_by)
VALUES 
('Test Broadcast - Combined Filters', 'Special offer for young female Gold members!', 'promotion', NOW(), '{"gender": ["female"], "subscription_tiers": ["gold"], "age_range": {"min": 18, "max": 25}}', (SELECT id FROM users WHERE is_admin = true LIMIT 1));

-- Test the filtering functions
-- These queries will show how many users match each filter criteria

SELECT 'All Users' as filter_type, COUNT(*) as user_count
FROM get_users_for_broadcast('{"all_users": true}'::jsonb);

SELECT 'Female Users' as filter_type, COUNT(*) as user_count  
FROM get_users_for_broadcast('{"gender": ["female"]}'::jsonb);

SELECT 'Age 18-21' as filter_type, COUNT(*) as user_count
FROM get_users_for_broadcast('{"age_range": {"min": 18, "max": 21}}'::jsonb);

SELECT 'Gold Tier' as filter_type, COUNT(*) as user_count
FROM get_users_for_broadcast('{"subscription_tiers": ["gold"]}'::jsonb);

SELECT 'Unverified Users' as filter_type, COUNT(*) as user_count
FROM get_users_for_broadcast('{"verification_status": ["unverified"]}'::jsonb);

-- Test combined filters
SELECT 'Female Gold 18-25' as filter_type, COUNT(*) as user_count
FROM get_users_for_broadcast('{"gender": ["female"], "subscription_tiers": ["gold"], "age_range": {"min": 18, "max": 25}}'::jsonb);

-- Show sample of users that would receive broadcasts
SELECT u.id, u.email, u.gender, u.subscription_tier, u.verification_status, 
       EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) as age
FROM get_users_for_broadcast('{"gender": ["female"], "age_range": {"min": 18, "max": 25}}'::jsonb) f
JOIN users u ON u.id = f.user_id
LIMIT 10;