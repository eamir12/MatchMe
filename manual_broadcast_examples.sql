-- Manual Admin Broadcast Usage Guide
-- This shows how to manually create and trigger broadcasts in Supabase

-- Step 1: Create a broadcast message (example: all users)
INSERT INTO admin_broadcasts (
    title, 
    message, 
    message_type, 
    scheduled_at, 
    filter_criteria, 
    action_url, 
    action_url_text,
    created_by
) VALUES (
    'Welcome Message', 
    'Welcome to MatchMe! Check out our new features.', 
    'info', 
    NOW(), -- Send immediately
    '{"all_users": true}', -- Filter: all users
    'https://matchme.app/features', -- Optional: clickable URL
    'Learn More', -- Optional: URL button text
    (SELECT id FROM users WHERE is_admin = true LIMIT 1) -- Admin user ID
);

-- Step 2: Create a targeted broadcast (example: Gold tier female users aged 18-25)
INSERT INTO admin_broadcasts (
    title, 
    message, 
    message_type, 
    scheduled_at, 
    filter_criteria,
    created_by
) VALUES (
    'Special Offer for Gold Members', 
    'Exclusive discount for our Gold members! Upgrade now and save 20%.', 
    'promotion', 
    NOW(), 
    '{"gender": ["female"], "subscription_tiers": ["gold"], "age_range": {"min": 18, "max": 25}}',
    (SELECT id FROM users WHERE is_admin = true LIMIT 1)
);

-- Step 3: Create a scheduled broadcast (example: send tomorrow at 9 AM)
INSERT INTO admin_broadcasts (
    title, 
    message, 
    message_type, 
    scheduled_at, 
    filter_criteria,
    created_by
) VALUES (
    'Morning Announcement', 
    'Good morning! Check out who liked you today.', 
    'info', 
    NOW() + INTERVAL '1 day' + INTERVAL '9 hours', -- Tomorrow at 9 AM
    '{"all_users": true}',
    (SELECT id FROM users WHERE is_admin = true LIMIT 1)
);

-- Step 4: Check broadcast status
SELECT 
    id,
    title,
    message,
    status,
    scheduled_at,
    actual_sent_count,
    created_at
FROM admin_broadcasts 
ORDER BY created_at DESC 
LIMIT 10;

-- Step 5: Check delivery status for a specific broadcast
SELECT 
    abd.user_id,
    u.email,
    abd.delivery_status,
    abd.delivered_at,
    abd.failure_reason
FROM admin_broadcast_deliveries abd
JOIN users u ON u.id = abd.user_id
WHERE abd.broadcast_id = 'your-broadcast-id-here'
ORDER BY abd.delivered_at DESC;

-- Common filter criteria examples:

-- All users
'{"all_users": true}'

-- All female users  
'{"gender": ["female"]}'

-- All male users
'{"gender": ["male"]}'

-- Users aged 18-21
'{"age_range": {"min": 18, "max": 21}}'

-- Gold tier users
'{"subscription_tiers": ["gold"]}'

-- Plus tier users  
'{"subscription_tiers": ["plus"]}'

-- Unverified users
'{"verification_status": ["unverified"]}'

-- Currently visible users only
'{"currently_visible": true}'

-- Multiple genders
'{"gender": ["female", "non_binary"]}'

-- Multiple subscription tiers
'{"subscription_tiers": ["gold", "platinum"]}'

-- Combined filters (female, Gold, aged 18-25)
'{"gender": ["female"], "subscription_tiers": ["gold"], "age_range": {"min": 18, "max": 25}}'

-- Users active in last 7 days
'{"last_active_days": 7}'

-- Platform specific (iOS users)
'{"platform": ["ios"]}'