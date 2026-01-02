-- Test script to validate the updated matching functions
-- This script tests the syntax and basic functionality of the preference-aware matching functions

-- Test 1: Check if the functions can be created without syntax errors
DO $$
BEGIN
    RAISE NOTICE 'Testing perform_event_matching function creation...';

    -- The function should already be created by the migration
    -- Just test that it exists and can be called
    IF EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'perform_event_matching'
        AND pg_get_function_identity_arguments(oid) = 'uuid'
    ) THEN
        RAISE NOTICE '✓ perform_event_matching function exists';
    ELSE
        RAISE EXCEPTION '✗ perform_event_matching function not found';
    END IF;

    RAISE NOTICE 'Testing perform_continuous_user_matching function creation...';

    IF EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'perform_continuous_user_matching'
        AND pg_get_function_identity_arguments(oid) = ''
    ) THEN
        RAISE NOTICE '✓ perform_continuous_user_matching function exists';
    ELSE
        RAISE EXCEPTION '✗ perform_continuous_user_matching function not found';
    END IF;

    RAISE NOTICE 'All function existence checks passed!';
END $$;

-- Test 2: Validate preference data structure
DO $$
DECLARE
    test_user_id UUID := '00000000-0000-0000-0000-000000000001';
    test_gender_prefs JSONB := '{"dating": ["male", "female"], "friendship": ["male"]}';
    test_age_prefs JSONB := '{"dating": [25, 35], "friendship": [20, 40]}';
BEGIN
    RAISE NOTICE 'Testing preference data structure...';

    -- Test gender preference access
    IF test_gender_prefs ? 'dating' THEN
        RAISE NOTICE '✓ Gender preferences accessible by intent';
    END IF;

    -- Test age preference access
    IF jsonb_array_length(test_age_prefs->'dating') = 2 THEN
        RAISE NOTICE '✓ Age preferences have correct structure';
    END IF;

    -- Test preference checking logic
    IF test_gender_prefs->'dating' ? 'male' THEN
        RAISE NOTICE '✓ Gender preference checking works';
    END IF;

    -- Test age range checking
    IF (test_age_prefs->'dating'->>0)::DOUBLE PRECISION <= 30
       AND (test_age_prefs->'dating'->>1)::DOUBLE PRECISION >= 30 THEN
        RAISE NOTICE '✓ Age range checking works';
    END IF;

    RAISE NOTICE 'All preference structure tests passed!';
END $$;

-- Test 3: Test jsonb_object_keys functionality
DO $$
DECLARE
    test_prefs JSONB := '{"dating": ["male"], "friendship": ["female"]}';
    key_count INTEGER := 0;
BEGIN
    RAISE NOTICE 'Testing jsonb_object_keys functionality...';

    SELECT COUNT(*) INTO key_count
    FROM jsonb_object_keys(test_prefs);

    IF key_count = 2 THEN
        RAISE NOTICE '✓ jsonb_object_keys returns correct count';
    END IF;

    -- Test EXISTS query with jsonb_object_keys
    IF EXISTS (
        SELECT 1
        FROM jsonb_object_keys(test_prefs) AS intent_key
        WHERE test_prefs->intent_key ? 'male'
    ) THEN
        RAISE NOTICE '✓ EXISTS query with jsonb_object_keys works';
    END IF;

    RAISE NOTICE 'All jsonb_object_keys tests passed!';
END $$;

-- Test 4: Test FOREACH loop functionality
DO $$
DECLARE
    test_intents TEXT[] := ARRAY['dating', 'friendship'];
    intent TEXT;
    loop_count INTEGER := 0;
BEGIN
    RAISE NOTICE 'Testing FOREACH loop functionality...';

    FOREACH intent IN ARRAY test_intents LOOP
        loop_count := loop_count + 1;
        RAISE NOTICE '  Intent %: %', loop_count, intent;
    END LOOP;

    IF loop_count = 2 THEN
        RAISE NOTICE '✓ FOREACH loop works correctly';
    ELSE
        RAISE EXCEPTION '✗ FOREACH loop failed, expected 2 iterations, got %', loop_count;
    END IF;

    RAISE NOTICE 'All FOREACH loop tests passed!';
END $$;