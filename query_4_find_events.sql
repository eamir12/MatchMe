-- Find events both users are attending
SELECT
    ea.event_id,
    e.event_name,
    e.start_time,
    COUNT(*) as total_attendees
FROM event_attendees ea
JOIN events e ON ea.event_id = e.id
WHERE ea.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
GROUP BY ea.event_id, e.event_name, e.start_time
HAVING COUNT(*) = 2 -- Both users attending
ORDER BY e.start_time DESC;