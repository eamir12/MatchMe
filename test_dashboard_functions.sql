-- Test the dashboard stats functions - Single query for Supabase compatibility
-- Run this entire query in Supabase SQL Editor to get all results at once

WITH function_check AS (
  -- Check if the functions exist
  SELECT
    'Function Check' as test_type,
    proname::text as identifier,
    CASE WHEN proname IS NOT NULL THEN 'EXISTS' ELSE 'MISSING' END as result
  FROM pg_proc
  WHERE proname IN ('get_online_users_count', 'get_nearby_users_count')
),

online_tests AS (
  -- Test online count for both users
  SELECT
    'Online Count' as test_type,
    '35fe114e-eae5-49d6-9eba-8459617e7b82' as identifier,
    get_online_users_count('35fe114e-eae5-49d6-9eba-8459617e7b82')::text as result
  UNION ALL
  SELECT
    'Online Count' as test_type,
    'ffc20046-a777-463b-922a-547151aa1455' as identifier,
    get_online_users_count('ffc20046-a777-463b-922a-547151aa1455')::text as result
),

nearby_tests AS (
  -- Test nearby count for both users
  SELECT
    'Nearby Count' as test_type,
    '35fe114e-eae5-49d6-9eba-8459617e7b82' as identifier,
    get_nearby_users_count('35fe114e-eae5-49d6-9eba-8459617e7b82', 50)::text as result
  UNION ALL
  SELECT
    'Nearby Count' as test_type,
    'ffc20046-a777-463b-922a-547151aa1455' as identifier,
    get_nearby_users_count('ffc20046-a777-463b-922a-547151aa1455', 50)::text as result
),

visibility_check AS (
  -- Check visibility status (new model: user_visibility_setting + system_visibility_status + online)
  SELECT
    'Visibility Status' as test_type,
    id::text as identifier,
    (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online = TRUE)
      AND COALESCE(user_visibility_setting,false) = TRUE
      AND COALESCE(system_visibility_status,'visible') = 'visible')::text as result
  FROM users
  WHERE id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
),

location_check AS (
  -- Check recent location updates
  SELECT
    'Location Data' as test_type,
    user_id::text as identifier,
    updated_at::text as result
  FROM user_locations
  WHERE user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
  ORDER BY updated_at DESC
  LIMIT 4
)

-- Combine all results
SELECT test_type, identifier, result FROM function_check
UNION ALL
SELECT test_type, identifier, result FROM online_tests
UNION ALL
SELECT test_type, identifier, result FROM nearby_tests
UNION ALL
SELECT test_type, identifier, result FROM visibility_check
UNION ALL
SELECT test_type, identifier, result FROM location_check
ORDER BY test_type, identifier;

-- DEBUG QUERIES: Run this single query to see all debug information at once

WITH debug_results AS (
  -- Check all visible users in the database (using new visibility predicate)
  SELECT 
    'All visible users' as check_type,
    COUNT(*)::text as count_value,
    NULL as user_id,
    NULL as is_visible,
    NULL as updated_at
  FROM users 
  WHERE (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online = TRUE)
    AND COALESCE(user_visibility_setting,false) = TRUE
    AND COALESCE(system_visibility_status,'visible') = 'visible') = true
  
  UNION ALL
  
  -- Check visible users excluding current user (using new visibility predicate)
  SELECT 
    'Visible users excluding current' as check_type,
    COUNT(*)::text as count_value,
    NULL as user_id,
    NULL as is_visible,
    NULL as updated_at
  FROM users 
  WHERE (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online = TRUE)
    AND COALESCE(user_visibility_setting,false) = TRUE
    AND COALESCE(system_visibility_status,'visible') = 'visible') = true AND id != '35fe114e-eae5-49d6-9eba-8459617e7b82'
  
  UNION ALL
  
  -- List all users and their visibility status (showing user setting)
  SELECT 
    'User visibility status' as check_type,
    NULL as count_value,
    id::text as user_id,
    COALESCE(user_visibility_setting,false)::text as is_visible,
    NULL as updated_at
  FROM users
  
  UNION ALL
  
  -- Check if there are any other users with recent locations
  SELECT 
    'Recent locations' as check_type,
    NULL as count_value,
    user_id::text as user_id,
    NULL as is_visible,
    updated_at::text as updated_at
  FROM user_locations
  WHERE updated_at > NOW() - INTERVAL '1 hour'
)

SELECT 
  check_type,
  COALESCE(count_value, 'N/A') as count,
  COALESCE(user_id, 'N/A') as user_id,
  COALESCE(is_visible, 'N/A') as is_visible,
  COALESCE(updated_at, 'N/A') as last_location_update
FROM debug_results
ORDER BY check_type, user_id;