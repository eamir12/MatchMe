-- Check event attendance for a specific event
SELECT
    ea.user_id,
    u.active_modes,
    u.shared_event_matching_enabled
FROM event_attendees ea
JOIN users u ON ea.user_id = u.id
WHERE ea.event_id = '6497a84c-6ae6-445b-b3e1-e7acc984b2c5';