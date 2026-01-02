-- Comprehensive diagnostic query to check Supabase matching functionality status
-- Run this query and paste the results back for analysis

-- 1. Check if continuous user matching function exists and is properly configured
SELECT
    proname as function_name,
    pg_get_function_identity_arguments(oid) as arguments,
    obj_description(oid, 'pg_proc') as description,
    proacl as permissions
FROM pg_proc
WHERE proname = 'perform_continuous_user_matching';

-- 2. Check if there's a trigger on user_locations table for automatic matching
SELECT
    trigger_name,
    event_manipulation,
    event_object_table,
    action_statement,
    action_timing
FROM information_schema.triggers
WHERE event_object_table = 'user_locations';

-- 3. Check for any scheduled jobs/cron jobs related to matching
-- Safely check cron jobs with comprehensive error handling
DO $$
DECLARE
    job_count INTEGER;
    match_jobs INTEGER;
    recent_runs INTEGER;
BEGIN
    RAISE NOTICE '=== CRON JOBS DIAGNOSTIC ===';

    -- Check if cron schema exists
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'cron') THEN
        RAISE NOTICE '✓ cron schema exists';

        -- Check if job table exists and what columns it has
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'cron' AND table_name = 'job') THEN
            RAISE NOTICE '✓ cron.job table exists';

            -- List all columns
            RAISE NOTICE 'cron.job columns:';
            PERFORM column_name FROM information_schema.columns
            WHERE table_schema = 'cron' AND table_name = 'job'
            ORDER BY ordinal_position;

            -- Try to count jobs (safely)
            BEGIN
                EXECUTE 'SELECT count(*) FROM cron.job' INTO job_count;
                RAISE NOTICE 'Total cron jobs: %', job_count;
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'Could not count cron jobs: %', SQLERRM;
                job_count := 0;
            END;

            -- Try to find match-related jobs using available columns
            IF job_count > 0 THEN
                BEGIN
                    EXECUTE 'SELECT count(*) FROM cron.job WHERE command LIKE ''%match%''' INTO match_jobs;
                    RAISE NOTICE 'Jobs with ''match'' in command: %', match_jobs;
                EXCEPTION WHEN OTHERS THEN
                    RAISE NOTICE 'Could not filter by command: %', SQLERRM;
                END;
            END IF;
        ELSE
            RAISE NOTICE '✗ cron.job table does not exist';
        END IF;

        -- Check job_run_details
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'cron' AND table_name = 'job_run_details') THEN
            RAISE NOTICE '✓ cron.job_run_details table exists';
            BEGIN
                EXECUTE 'SELECT count(*) FROM cron.job_run_details WHERE start_time >= NOW() - INTERVAL ''24 hours''' INTO recent_runs;
                RAISE NOTICE 'Recent cron job runs (24h): %', recent_runs;
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'Could not check recent runs: %', SQLERRM;
            END;
        ELSE
            RAISE NOTICE '✗ cron.job_run_details table does not exist';
        END IF;

    ELSE
        RAISE NOTICE '✗ cron schema does not exist - no scheduled jobs configured';
    END IF;
END $$;

-- 4. Check if the function has proper permissions
SELECT
    grantee,
    privilege_type
FROM information_schema.role_routine_grants
WHERE routine_name = 'perform_continuous_user_matching';

-- 5. Check current state of user_locations and matches tables
SELECT
    'user_locations' as table_name,
    COUNT(*) as record_count,
    MIN(updated_at) as oldest_update,
    MAX(updated_at) as newest_update
FROM user_locations
UNION ALL
SELECT
    'matches' as table_name,
    COUNT(*) as record_count,
    MIN(created_at) as oldest_match,
    MAX(created_at) as newest_match
FROM matches;

-- 6. Check if users are visible and have recent locations
SELECT
    COUNT(*) as visible_users_with_recent_locations
FROM user_locations ul
INNER JOIN users u ON ul.user_id = u.id
WHERE public.is_user_truly_visible(u.id) = TRUE
AND ul.updated_at >= NOW() - INTERVAL '1 hour';

-- 7. Check function search path configuration
SELECT
    current_setting('search_path') as current_search_path;

-- 8. Test if the function can be executed (this will show if there are any immediate errors)
DO $$
BEGIN
    RAISE NOTICE '=== FUNCTION EXECUTION TEST ===';
    RAISE NOTICE 'Testing perform_continuous_user_matching function...';

    -- Check if function exists
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'perform_continuous_user_matching') THEN
        RAISE NOTICE '✓ Function exists';

        -- Try to call it (this will fail safely if there are permission or other issues)
        BEGIN
            -- Note: We don't actually execute it here as it would create real matches
            -- Just test that it's callable by the current user
            PERFORM has_function_privilege(current_user, 'perform_continuous_user_matching()', 'execute');
            RAISE NOTICE '✓ Current user has execute permission';
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '✗ Permission check failed: %', SQLERRM;
        END;
    ELSE
        RAISE NOTICE '✗ Function does not exist';
    END IF;
END $$;

-- 9. Check for any recent matches created (last 24 hours)
SELECT
    COUNT(*) as matches_last_24h,
    COUNT(*) FILTER (WHERE match_type = 'proximity') as proximity_matches,
    COUNT(*) FILTER (WHERE match_type = 'event') as event_matches
FROM matches
WHERE created_at >= NOW() - INTERVAL '24 hours';