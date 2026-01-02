-- Test script for updated matching functions with preferences
-- Run this in Supabase SQL editor after deploying the migration script
-- Date: December 26, 2025

-- Test 1: Check if functions exist and are accessible
SELECT
    proname as function_name,
    pg_get_function_identity_arguments(oid) as arguments,
    obj_description(oid, 'pg_proc') as description
FROM pg_proc
WHERE proname IN ('perform_event_matching', 'perform_continuous_user_matching')
ORDER BY proname;

-- Test 2: Validate function syntax by calling with invalid parameters (should fail gracefully)
-- This tests that the functions are properly created and can handle errors
DO $$
BEGIN
    -- Test perform_event_matching with null parameter
    BEGIN
        PERFORM perform_event_matching(NULL);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'perform_event_matching correctly rejected null parameter: %', SQLERRM;
    END;

    -- Test perform_continuous_user_matching (no parameters needed)
    BEGIN
        SELECT * FROM perform_continuous_user_matching();
        RAISE NOTICE 'perform_continuous_user_matching executed successfully';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'perform_continuous_user_matching error: %', SQLERRM;
    END;
END $$;

-- Test 3: Check that preference columns exist in users table
SELECT
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_name = 'users'
    AND column_name IN ('gender_preferences', 'age_preferences', 'strict_gender_age_enforcement')
ORDER BY column_name;

-- Test 4: Sample preference data validation
-- Check if any users have preference data (should show structure if exists)
SELECT
    COUNT(*) as users_with_gender_prefs,
    COUNT(CASE WHEN gender_preferences IS NOT NULL THEN 1 END) as users_with_gender_prefs_set,
    COUNT(CASE WHEN age_preferences IS NOT NULL THEN 1 END) as users_with_age_prefs_set,
    COUNT(CASE WHEN strict_gender_age_enforcement = true THEN 1 END) as users_with_strict_enforcement
FROM users;

-- Test 5: Check for existing matches table structure
SELECT
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_name = 'matches'
ORDER BY ordinal_position;

-- Success message
SELECT 'All validation tests completed. Check the notices above for any issues.' as status;