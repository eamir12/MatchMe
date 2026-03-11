-- ============================================================================
-- DIAGNOSTIC: Check what triggers translations on chat_messages
-- ============================================================================
-- Run this in Supabase SQL Editor to see ALL translation mechanisms
-- ============================================================================

-- 1. Check for triggers on chat_messages table
SELECT 
    t.tgname as trigger_name,
    p.proname as function_name,
    CASE t.tgtype & 1
        WHEN 1 THEN 'ROW'
        ELSE 'STATEMENT'
    END as level,
    CASE t.tgtype & 66
        WHEN 2 THEN 'BEFORE'
        WHEN 64 THEN 'INSTEAD OF'
        ELSE 'AFTER'
    END as action_timing,
    CASE 
        WHEN t.tgtype & 4 = 4 THEN 'INSERT'
        WHEN t.tgtype & 8 = 8 THEN 'DELETE'
        WHEN t.tgtype & 16 = 16 THEN 'UPDATE'
    END as event_manipulation
FROM pg_trigger t
JOIN pg_proc p ON t.tgfoid = p.oid
WHERE t.tgrelid = 'public.chat_messages'::regclass
  AND NOT t.tgisinternal
ORDER BY t.tgname;

-- 2. Check for edge function webhooks (Supabase database webhooks)
-- Note: Database webhooks are stored differently
SELECT 
    w.name as webhook_name,
    w.uri as webhook_url,
    w.events as events,
    w.table_name
FROM supabase_extensions.webhooks w
WHERE w.table_name = 'chat_messages';

-- 3. Check for functions that might be calling HTTP (like the old auto_translate)
SELECT proname, prosrc
FROM pg_proc
WHERE proname LIKE '%translate%'
   OR prosrc LIKE '%translate-proxy%'
   OR prosrc LIKE '%http_post%';

-- 4. List all functions with 'auto' in the name that might auto-translate
SELECT proname
FROM pg_proc
WHERE proname LIKE '%auto%'
  AND pronamespace = 'public'::regnamespace;

-- ============================================================================
-- EXPECTED RESULT AFTER FIX:
-- ============================================================================
-- 1. No triggers with 'translate' or 'auto_translate' in the name should exist
-- 2. A webhook named 'chat_messages_translation_webhook' should exist (via Supabase Dashboard)
-- 3. No functions calling http_post to translate-proxy should exist (the old trigger method)
-- ============================================================================
