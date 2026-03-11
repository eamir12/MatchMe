-- ============================================================================
-- VERIFY: Webhook sends correct payload AND function builds context
-- ============================================================================
-- This diagnostic verifies:
-- 1. Webhook is sending required fields (match_id, sender_id, content_original)
-- 2. Users have gender information for context building
-- 3. Chats have translation settings configured
-- ============================================================================

-- 1. Check if users in recent matches have gender set
SELECT 
    u.id as user_id,
    u.gender
FROM users u
WHERE u.gender IS NOT NULL
LIMIT 10;

-- 2. Check translation settings for recent chats
SELECT 
    c.id as chat_id,
    c.match_id,
    c.user_id,
    c.other_user_id,
    c.translation_enabled,
    c.translation_language
FROM chats c
WHERE c.translation_enabled = true
LIMIT 10;

-- 3. Check if there's a match with two users who both have gender set
SELECT 
    m.id as match_id,
    m.user1_id,
    u1.gender as user1_gender,
    m.user2_id,
    u2.gender as user2_gender
FROM matches m
JOIN users u1 ON m.user1_id = u1.id
JOIN users u2 ON m.user2_id = u2.id
WHERE u1.gender IS NOT NULL 
  AND u2.gender IS NOT NULL
LIMIT 5;

-- 4. Check recent chat_messages to see what the webhook would send
SELECT 
    cm.id as message_id,
    cm.match_id,
    cm.sender_id,
    cm.content_original,
    cm.content_translated,
    cm.created_at
FROM chat_messages cm
ORDER BY cm.created_at DESC
LIMIT 5;

-- ============================================================================
-- WHAT TRANSLATE-PROXY DOES WITH WEBHOOK PAYLOAD:
-- ============================================================================
-- 1. Receives: { record: { id, match_id, sender_id, content_original } }
-- 2. Queries chats table: finds recipient (user_id != sender_id)
-- 3. Gets recipient's translation_language
-- 4. Calls buildDeepLEnhancements():
--    - Gets sender.gender from users table
--    - Gets recipient.gender from users table  
--    - Builds context: "This is a casual chat message between two people. 
--                       The sender is {sender_gender}. The recipient is {recipient_gender}."
--    - Builds custom_instructions: "Use {sender_gender} grammatical forms 
--                                    for the speaker and {recipient_gender} forms 
--                                    when addressing the recipient."
-- 5. Sends to DeepL with context + custom_instructions
-- ============================================================================

-- ============================================================================
-- HOW TO VERIFY IN LOGS:
-- ============================================================================
-- After sending a message, check translate-proxy logs for:
-- "🔄 Translate-Proxy: Processing webhook payload"  <- webhook path
-- "🔄 Translate-Proxy: Built DeepL enhancements: {..., 
--       context: 'This is a casual chat message between two people. 
--                 The sender is non_binary. The recipient is female.',  
--       customInstructions: ['Use non_binary grammatical forms...']}"
-- ============================================================================
