-- Check if functions have SET search_path
SELECT
    proname as function_name,
    pg_get_functiondef(oid) as function_definition
FROM pg_proc
WHERE proname IN (
    'trigger_set_timestamp',
    'trigger_perform_event_matching',
    'mark_messages_as_read',
    'perform_event_matching_debug',
    'find_shared_events',
    'get_recent_chats',
    'get_potential_event_matches',
    'perform_event_matching',
    'get_online_users_count',
    'get_nearby_users_count',
    'count_event_attendees'
)
ORDER BY proname;