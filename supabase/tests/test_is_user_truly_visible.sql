-- Test cases for public.is_user_truly_visible(p_user_id UUID)
-- Create temporary users and user_activity rows and assert the function results

-- NOTE: Run these in a disposable/staging DB

-- Clean up any existing test users (by email unique marker)
DELETE FROM users WHERE email LIKE 'test_visibility_%';

-- Insert test users
INSERT INTO users (id, email, name, user_visibility_setting, system_visibility_status, created_at)
VALUES
  ('00000000-0000-0000-0000-000000000001', 'test_visibility_visible@example.com', 'Visible User', true, 'visible', NOW()),
  ('00000000-0000-0000-0000-000000000002', 'test_visibility_manual_off@example.com', 'Manual Off', false, 'visible', NOW()),
  ('00000000-0000-0000-0000-000000000003', 'test_visibility_system_invisible@example.com', 'System Invisible', true, 'invisible', NOW()),
  ('00000000-0000-0000-0000-000000000004', 'test_visibility_offline@example.com', 'Offline User', true, 'visible', NOW()),
  ('00000000-0000-0000-0000-000000000005', 'test_visibility_pinned_offline@example.com', 'Pinned Offline User', true, 'visible', NOW()),
  ('00000000-0000-0000-0000-000000000006', 'test_visibility_pin_expired@example.com', 'Pin Expired User', true, 'visible', NOW());

-- Ensure user_activity rows
DELETE FROM user_activity WHERE user_id LIKE '00000000-0000-0000-0000-00000000000%';
INSERT INTO user_activity (user_id, is_online, last_activity) VALUES
  ('00000000-0000-0000-0000-000000000001', TRUE, NOW()),
  ('00000000-0000-0000-0000-000000000002', TRUE, NOW()),
  ('00000000-0000-0000-0000-000000000003', TRUE, NOW()),
  ('00000000-0000-0000-0000-000000000004', FALSE, NOW() - INTERVAL '1 hour'),
  -- 5 and 6 have no live heartbeat: their app is closed (pin means no GPS,
  -- so no location ticks either). Only the pin state differs between them.
  ('00000000-0000-0000-0000-000000000005', FALSE, NOW() - INTERVAL '1 hour'),
  ('00000000-0000-0000-0000-000000000006', FALSE, NOW() - INTERVAL '1 hour');

-- Pinned location rows: user 5 holds an ACTIVE pin, user 6's pin expired.
DELETE FROM user_locations WHERE user_id IN (
  '00000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000006');
INSERT INTO user_locations (user_id, latitude, longitude, updated_at, is_pinned, pinned_expires_at) VALUES
  ('00000000-0000-0000-0000-000000000005', 52.5200, 13.4050, NOW() - INTERVAL '2 hours', TRUE, NOW() + INTERVAL '23 hours'),
  ('00000000-0000-0000-0000-000000000006', 52.5200, 13.4050, NOW() - INTERVAL '2 hours', TRUE, NOW() - INTERVAL '1 hour');

-- Check results
SELECT id, email, public.is_user_truly_visible(id) as is_truly_visible
FROM users
WHERE email LIKE 'test_visibility_%'
ORDER BY email;
-- Expect: visible user => true; manual_off => false; system_invisible => false;
--         offline => false;
--         pinned_offline => true  (active pin replaces the heartbeat + fresh-location requirement)
--         pin_expired   => false (expired pin grants nothing until live GPS/heartbeat returns)

-- Cleanup (optional)
-- DELETE FROM user_activity WHERE user_id LIKE '00000000-0000-0000-0000-00000000000%';
-- DELETE FROM users WHERE email LIKE 'test_visibility_%';
