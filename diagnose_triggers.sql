-- Diagnostic: find ALL triggers on public.users and their function name
SELECT
  tgname AS trigger_name,
  t.tgtype::integer AS trigger_type,
  p.proname AS function_name
FROM pg_trigger t
JOIN pg_proc p ON p.oid = t.tgfoid
WHERE t.tgrelid = 'public.users'::regclass
  AND NOT t.tgisinternal
ORDER BY p.proname;

-- Show the function source for each trigger on public.users
SELECT
  n.nspname AS schema_name,
  p.proname AS function_name,
  p.prosrc AS function_source
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_trigger t ON t.tgfoid = p.oid
WHERE t.tgrelid = 'public.users'::regclass
  AND NOT t.tgisinternal
ORDER BY n.nspname, p.proname;

-- Search all functions for approved_primary_photos references
SELECT
  n.nspname AS schema_name,
  p.proname AS function_name,
  p.prosrc AS function_source
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.prosrc ILIKE '%approved_primary_photos%'
ORDER BY n.nspname, p.proname;

-- Find ALL triggers on ALL tables that use these functions
SELECT
  t.tgname AS trigger_name,
  c.relname AS table_name,
  n.nspname AS table_schema,
  p.proname AS function_name
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_proc p ON p.oid = t.tgfoid
WHERE p.proname IN ('prevent_sensitive_user_field_updates', 'approve_primary_photo', 'block_protected_user_fields_update')
ORDER BY n.nspname, c.relname, t.tgname;
