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

-- 2. Inspect database webhooks (Supabase implements them as triggers using
-- supabase_functions.http_request). URL/method only: headers can contain
-- secrets, so this query reports header presence without printing values.
WITH trigger_args AS (
    SELECT
        t.tgname,
        t.tgenabled,
        encode(t.tgargs, 'escape') AS raw_args,
        string_to_array(encode(t.tgargs, 'escape'), E'\\000') AS args
    FROM pg_trigger t
    WHERE t.tgrelid = 'public.chat_messages'::regclass
      AND NOT t.tgisinternal
)
SELECT
    tgname AS webhook_name,
    CASE tgenabled
        WHEN 'O' THEN 'enabled'
        WHEN 'D' THEN 'disabled'
        ELSE tgenabled::text
    END AS enabled,
    args[1] AS webhook_url,
    args[2] AS http_method,
    raw_args LIKE '%x-matchme-webhook-secret%' AS has_webhook_secret_header,
    raw_args LIKE '%Authorization%' AS has_authorization_header
FROM trigger_args
WHERE args[1] LIKE '%translate-proxy%'
   OR raw_args LIKE '%translate-proxy%'
ORDER BY tgname;

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
-- 1. No auto_translate_on_insert trigger/function should exist.
-- 2. Exactly one enabled webhook trigger (for example "Chat Translation")
--    should point to /functions/v1/translate-proxy on INSERT.
-- 3. The reset_translation_status_on_edit trigger should exist.
-- 4. Old call_translate_proxy_edge_function overloads may remain, but must not
--    be attached to a trigger or called by the client. They can be dropped
--    after verifying no dependencies.
-- ============================================================================
