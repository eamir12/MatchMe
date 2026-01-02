-- Diagnostic queries to verify continuous event matching setup

-- 1. Check if the continuous matching function exists
SELECT
    proname,
    pg_get_function_identity_arguments(oid) as arguments,
    obj_description(oid, 'pg_proc') as description
FROM pg_proc
WHERE proname = 'perform_continuous_event_matching';

-- 2. Check if there are any events with attendees
SELECT
    e.id,
    e.title,
    e.event_date,
    COUNT(ea.user_id) as attendee_count
FROM events e
LEFT JOIN event_attendees ea ON e.id = ea.event_id
WHERE e.event_date >= CURRENT_DATE
GROUP BY e.id, e.title, e.event_date
HAVING COUNT(ea.user_id) > 0
ORDER BY e.event_date;

-- 3. Check users with event matching enabled
SELECT
    u.id,
    u.active_modes,
    u.shared_event_matching_enabled,
    COALESCE(u.user_visibility_setting,false) as user_visibility_setting,
    COUNT(DISTINCT ea.event_id) as events_attending
FROM users u
LEFT JOIN event_attendees ea ON u.id = ea.user_id
WHERE u.shared_event_matching_enabled = true
GROUP BY u.id, u.active_modes, u.shared_event_matching_enabled, COALESCE(u.user_visibility_setting,false);

-- 4. Check if users have interests data
SELECT
    up.user_id,
    jsonb_object_keys(COALESCE(up.profile_data->'interests', '{}')) as interest_categories,
    up.profile_data->'interests' as interests
FROM user_profiles up
WHERE up.profile_data ? 'interests'
LIMIT 10;

-- 5. Check recent matches (last 24 hours)
SELECT
    m.id,
    m.user1_id,
    m.user2_id,
    m.match_type,
    m.matched_intent,
    m.event_id,
    m.created_at,
    e.title as event_title
FROM matches m
LEFT JOIN events e ON m.event_id = e.id
WHERE m.created_at >= NOW() - INTERVAL '24 hours'
ORDER BY m.created_at DESC;

-- 6. Test the function manually (replace with actual event ID if needed)
-- SELECT perform_continuous_event_matching();

-- 7. Check cron job status
SELECT
    jobid,
    jobname,
    schedule,
    command,
    nodename,
    nodeport,
    database,
    username,
    active,
    jobpid
FROM cron.job
WHERE jobname = 'continuous-event-matching';

-- 8. Check cron job run history (last 10 runs)
SELECT
    jobid,
    jobname,
    status,
    return_message,
    start_time,
    end_time
FROM cron.job_run_details
WHERE jobname = 'continuous-event-matching'
ORDER BY start_time DESC
LIMIT 10;