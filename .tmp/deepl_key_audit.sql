-- ============================================================================
-- DeepL key audit (read-only) — run BEFORE the cleanup migration.
-- Answers:
--   1. Does app_config still have the old key/value columns, config_key/value,
--      or both?
--   2. Is there a deepl_api_key row, and does it hold a REAL key or the
--      'YOUR_DEEPL_API_KEY_HERE' placeholder? (Preview is masked.)
--   3. Is the legacy auto-translate trigger still attached to chat_messages?
-- ============================================================================

-- 1. Actual columns on app_config
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'app_config'
ORDER BY ordinal_position;

-- 2. deepl_api_key row, old key/value style (masked preview)
SELECT key, left(value, 10) AS value_prefix, length(value) AS value_len, 'old key/value' AS style
FROM public.app_config
WHERE key = 'deepl_api_key';

-- 2b. deepl_api_key row, new config_key/config_value style (masked preview)
SELECT config_key, left(config_value::text, 10) AS value_prefix,
       length(config_value::text) AS value_len, 'config_key/config_value' AS style
FROM public.app_config
WHERE config_key = 'deepl_api_key';

-- 3. Triggers on chat_messages (is auto_translate still attached?)
SELECT tgname AS trigger_name,
       tgenabled AS enabled,   -- 'O' = enabled, 'D' = disabled
       pg_get_triggerdef(t.oid) AS definition
FROM pg_trigger t
WHERE tgrelid = 'public.chat_messages'::regclass
  AND NOT tgisinternal;

-- 4. Any other function still reading the app_config deepl row?
SELECT p.proname
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND pg_get_functiondef(p.oid) LIKE '%deepl_api_key%';
