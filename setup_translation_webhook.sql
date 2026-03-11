-- ============================================================================
-- SETUP: Database Webhook for Automatic Message Translation
-- ============================================================================
-- This migration creates a database webhook that calls translate-proxy
-- whenever a new message is inserted into chat_messages table.
--
-- PREREQUISITES:
-- 1. You need to set up this webhook via Supabase Dashboard or CLI
-- 2. The translate-proxy edge function must be deployed
--
-- ============================================================================

-- STEP 1: Verify translate-proxy is deployed
-- Run this in Supabase Dashboard → Edge Functions to confirm translate-proxy exists

-- STEP 2: Create the webhook via Supabase Dashboard
-- 
-- Go to: https://supabase.com/dashboard/project/vazkmvrbshxwyodentng/database/webhooks
-- 
-- Click "Create a new webhook" and fill in:
--   - Name: chat_messages_translation_webhook
--   - Table: chat_messages  
--   - Events: Insert
--   - URL: https://vazkmvrbshxwyodentng.supabase.co/functions/v1/translate-proxy
--   - Headers: 
--       Authorization: Bearer YOUR_SERVICE_ROLE_KEY
--       Content-Type: application/json
--   - Refresh: Enable
--
-- IMPORTANT: The webhook will send a payload like:
-- {
--   "type": "INSERT",
--   "table": "chat_messages",
--   "record": {
--     "id": "message-uuid",
--     "match_id": "match-uuid", 
--     "sender_id": "sender-uuid",
--     "content_original": "Hello in Hebrew",
--     ...
--   }
-- }
--
-- The translate-proxy function detects this format (body.record exists)
-- and processes it with full context (sender/recipient gender, etc.)
--
-- ============================================================================

-- STEP 3: Verify the webhook is working
-- After setting up, insert a test message and check the translate-proxy logs

-- ============================================================================
-- ALTERNATIVE: Using Supabase CLI (if available)
-- ============================================================================
-- If you have Supabase CLI installed, you can create the webhook via CLI:
--
-- supabase db webhook create \
--   --name chat_messages_translation_webhook \
--   --table chat_messages \
--   --insert \
--   "https://vazkmvrbshxwyodentng.supabase.co/functions/v1/translate-proxy"
--
-- ============================================================================

-- Verify current triggers on chat_messages (for reference)
SELECT tgname as trigger_name, proname as function_name
FROM pg_trigger t
JOIN pg_proc p ON t.tgfoid = p.oid
WHERE tgrelid = 'public.chat_messages'::regclass
  AND NOT t.tgisinternal;

-- Check for any webhook configurations in supabase
SELECT * FROM supabase_functions.functions WHERE name LIKE '%translate%';

-- List all database webhooks
SELECT * FROM pg_webhook.webhooks;
