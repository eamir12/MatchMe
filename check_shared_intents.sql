-- Check if Edge and Android users have shared intents
SELECT
    u1.id as user1_id,
    u1.name as user1_name,
    u1.active_modes as user1_intents,
    u2.id as user2_id,
    u2.name as user2_name,
    u2.active_modes as user2_intents,
    CASE
        WHEN u1.active_modes IS NULL OR u2.active_modes IS NULL THEN 'NULL_INTENTS'
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
