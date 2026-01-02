-- Comprehensive fix for Edge and Android user matching issue
-- This script addresses multiple potential causes of matching failure

-- ==========================================
-- STEP 1: Create trigger for immediate matching on location updates
-- ==========================================

CREATE OR REPLACE FUNCTION trigger_perform_user_location_matching()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';

    -- Only trigger on INSERT or UPDATE (when location is added/updated)
    IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        -- Call the continuous user matching function
        -- This will check for matches involving users with recent location updates
        PERFORM perform_continuous_user_matching();
    END IF;

    RETURN NEW;
END;
$$;

-- Create the trigger on user_locations table
DROP TRIGGER IF EXISTS trigger_user_location_matching ON user_locations;
CREATE TRIGGER trigger_user_location_matching
    AFTER INSERT OR UPDATE ON user_locations
    FOR EACH STATEMENT  -- Use STATEMENT level to avoid multiple calls
    EXECUTE FUNCTION trigger_perform_user_location_matching();

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION trigger_perform_user_location_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION trigger_perform_user_location_matching() TO anon;

-- ==========================================
-- STEP 2: Verify the continuous matching function exists and works
-- ==========================================

-- Check if function exists
SELECT
    'Function Check' as check_type,
    CASE WHEN proname IS NOT NULL THEN '✓ EXISTS' ELSE '✗ MISSING' END as status,
    proname as function_name
FROM pg_proc
WHERE proname = 'perform_continuous_user_matching';

-- ==========================================
-- STEP 3: Test matching with detailed logging
-- ==========================================

-- Enable detailed logging for debugging
SET client_min_messages = 'NOTICE';

-- Check current state of Edge and Android users
SELECT
    'USER STATUS CHECK' as check_phase,
    u.id,
    u.name,
    COALESCE(u.user_visibility_setting,false) as user_visibility_setting,
    u.active_modes,
    u.match_radius_default,
    ul.latitude,
    ul.longitude,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_since_location_update,
    CASE
        WHEN COALESCE(u.user_visibility_setting,false) = TRUE AND ul.updated_at >= NOW() - INTERVAL '1 hour' THEN 'READY_FOR_MATCHING'
        ELSE 'NOT_READY'
    END as matching_status
FROM users u
LEFT JOIN user_locations ul ON u.id = ul.user_id
    AND ul.updated_at >= NOW() - INTERVAL '1 hour'
WHERE u.id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455');

-- Check their interests
SELECT
    'INTERESTS CHECK' as check_phase,
    u.id,
    u.name,
    up.profile_data->'interests' as interests
FROM users u
LEFT JOIN user_profiles up ON u.id = up.user_id
WHERE u.id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
AND up.profile_data ? 'interests';

-- Test the find_nearby_users function directly
SELECT
    'NEARBY USERS TEST' as check_phase,
    fnu.*
FROM find_nearby_users(
    '35fe114e-eae5-49d6-9eba-8459617e7b82',
    (SELECT latitude FROM user_locations WHERE user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' ORDER BY updated_at DESC LIMIT 1),
    (SELECT longitude FROM user_locations WHERE user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' ORDER BY updated_at DESC LIMIT 1),
    10.0  -- 10km radius
) fnu
WHERE fnu.user_id = 'ffc20046-a777-463b-922a-547151aa1455';

-- Check if they have shared intents
SELECT
    'SHARED INTENTS CHECK' as check_phase,
    u1.id as user1_id,
    u1.name as user1_name,
    u1.active_modes as user1_intents,
    u2.id as user2_id,
    u2.name as user2_name,
    u2.active_modes as user2_intents,
    CASE
        WHEN u1.active_modes && u2.active_modes THEN 'HAS_SHARED_INTENTS'
        ELSE 'NO_SHARED_INTENTS'
    END as intent_status,
    CASE
        WHEN u1.active_modes && u2.active_modes THEN
            ARRAY(SELECT unnest(u1.active_modes) INTERSECT SELECT unnest(u2.active_modes))
        ELSE ARRAY[]::TEXT[]
    END as shared_intents
FROM users u1
CROSS JOIN users u2
WHERE u1.id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
AND u2.id = 'ffc20046-a777-463b-922a-547151aa1455';

-- Check existing matches
SELECT
    'EXISTING MATCHES CHECK' as check_phase,
    COUNT(*) as existing_matches_between_users
FROM matches
WHERE (user1_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' AND user2_id = 'ffc20046-a777-463b-922a-547151aa1455')
   OR (user1_id = 'ffc20046-a777-463b-922a-547151aa1455' AND user2_id = '35fe114e-eae5-49d6-9eba-8459617e7b82');

-- ==========================================
-- STEP 4: Run the continuous matching function
-- ==========================================

SELECT 'RUNNING CONTINUOUS MATCHING...' as status_message;

-- Run the continuous matching function
SELECT * FROM perform_continuous_user_matching();

-- ==========================================
-- STEP 5: Check results
-- ==========================================

-- Check if any new matches were created
SELECT
    'MATCHING RESULTS' as check_phase,
    m.id,
    m.user1_id,
    m.user2_id,
    m.match_type,
    m.matched_intent,
    m.created_at,
    u1.name as user1_name,
    u2.name as user2_name
FROM matches m
JOIN users u1 ON m.user1_id = u1.id
JOIN users u2 ON m.user2_id = u2.id
WHERE (m.user1_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
   OR m.user2_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455'))
   AND m.created_at >= NOW() - INTERVAL '5 minutes'
ORDER BY m.created_at DESC;

-- ==========================================
-- STEP 6: Cron job setup instructions
-- ==========================================

-- CRON JOB SETUP INSTRUCTIONS:
-- 1. Go to Supabase Dashboard > Edge Functions
-- 2. Find the 'cron-jobs' function
-- 3. Set up a cron schedule:
--    - Recommended: every 15-30 minutes
--    - Cron expression: */15 * * * * (every 15 minutes)
--    - Or: */30 * * * * (every 30 minutes)
--
-- The cron job will automatically run:
-- - handleInvisibilitySchedules()
-- - handleContinuousEventMatching()
-- - handleContinuousUserMatching()
--
-- This provides both immediate reactive matching (via triggers) and periodic continuous matching (via cron).

-- ==========================================
-- STEP 7: Manual testing instructions
-- ==========================================

-- MANUAL TESTING:
-- If the automatic matching doesn't work, you can test manually:
-- 1. Run this script in Supabase SQL Editor
-- 2. Check the results in the "MATCHING RESULTS" section
-- 3. If no matches are created, check the diagnostic output above
--
-- Common issues:
-- - Users not visible
-- - No recent location updates (older than 1 hour)
-- - No shared intents
-- - No shared interests
-- - Users already matched
-- - Matching function errors

SELECT 'DIAGNOSTIC COMPLETE - Check results above' as final_status;
