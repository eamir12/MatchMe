-- ============================================================================
-- SECRET LEAK AUDIT (read-only) — run in Supabase SQL Editor.
-- Covers every place a credential could hide in the live database:
-- app_config rows, database/role settings, Vault, exposed tables' columns,
-- client-callable functions that touch secrets, public storage buckets,
-- and webhook triggers with embedded tokens.
-- No secret values are printed; everything is masked or name-only.
-- ============================================================================

-- ============================================================================
-- 1. app_config — full key inventory. Any name matching a secret-ish pattern
-- is flagged. Values are NOT printed.
-- Expected: flags on nothing (feature flags only). If a key named like
-- *_api_key / *_secret / *_token shows up, investigate it.
-- ============================================================================
SELECT
  config_key,
  (config_key ~* '(key|secret|token|password|credential|api|private)' AND config_key <> 'ads.config_version')
    AS review_this_key
FROM public.app_config
ORDER BY config_key;

-- 1b. app_config — secret-LIKE VALUES regardless of name (masked prefix only).
-- Patterns: JWTs, Google/Skylake keys, DeepL (:fx), AWS, PEM bodies, long hex.
-- Expected: zero rows.
SELECT config_key,
       left(config_value::text, 8) AS value_prefix,
       length(config_value::text)  AS value_len
FROM public.app_config
WHERE config_value::text ~* '(eyJ[A-Za-z0-9_-]{20}|sk-[a-zA-Z0-9]{10}|AIzaSy|AKIA[A-Z0-9]{8}|BEGIN (RSA |EC )?PRIVATE|:fx$|-----BE[GI])'
   OR config_value::text ~ '^[a-f0-9]{40,}$';
-- (Note: 'ads.config_version' holds a timestamp — it cannot match these.)

-- ============================================================================
-- 2. Database / role-level settings — the Jan-2026 migration
--    (20260106004100) suggested storing the DeepL key via set_config /
--    ALTER DATABASE ... SET. If anyone did that with a real key, it persists.
-- Expected: both NULL (or empty).
-- ============================================================================
SELECT
  current_setting('app.deepl_api_key', true)  AS app_deepl_setting,
  current_setting('deepl_api_key', true)      AS plain_deepl_setting,
  (SELECT count(*) FROM pg_db_role_setting)   AS db_role_setting_rows;

-- If db_role_setting_rows > 0, inspect which database/role and which settings:
-- SELECT * FROM pg_db_role_setting;   -- setdatabase 0 = all databases
-- SELECT setconfig FROM pg_db_role_setting WHERE setconfig <> '{}';

-- ============================================================================
-- 3. Supabase Vault — secret names only (values are encrypted and are NOT
-- printed). Expected: whatever the team stored; vault is safe by design
-- (access-controlled, encrypted at rest).
-- ============================================================================
SELECT name, created_at
FROM vault.secrets
ORDER BY created_at;

-- ============================================================================
-- 4. Tables that authenticated/anon clients can read directly, and whether
-- they have any column whose NAME suggests secrets. These are the tables a
-- signed-in client could query via PostgREST.
-- Expected: app_config appears (feature flags only — verified above);
-- ad_units/ad_networks (public ad config, fine); translations (text, fine).
-- Any OTHER table with secret-ish columns + a permissive policy = review.
-- ============================================================================
SELECT DISTINCT
  pol.schemaname || '.' || pol.tablename AS table_name,
  pol.cmd,
  pol.roles
FROM pg_policies pol
WHERE pol.cmd IN ('SELECT', 'ALL')
  AND (
    pol.roles::text LIKE '%anon%'
    OR pol.tablename IN (
      SELECT tablename FROM pg_policies
      WHERE cmd IN ('SELECT','ALL') AND roles::text LIKE '%authenticated%'
    )
  )
AND EXISTS (
  SELECT 1
  FROM information_schema.columns c
  WHERE c.table_schema = pol.schemaname
    AND c.table_name   = pol.tablename
    AND c.column_name ~* '(key|secret|token|password|credential|private)'
)
ORDER BY 1;

-- 4b. For any table flagged above, see the exact column names (this query
-- lists ALL such columns schema-wide so you can eyeball them):
SELECT table_schema, table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name ~* '(secret|password|credential|private_key|api_key|service_account)'
ORDER BY table_name, column_name;

-- ============================================================================
-- 5. Functions callable by authenticated/anon whose body touches secrets
-- (vault, current_setting, api_key, service_role). SECURITY DEFINER fns run
-- with elevated rights, so a careless one could expose a secret to clients.
-- Expected: none (or only ones you recognize as safe).
-- ============================================================================
SELECT
  n.nspname || '.' || p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS args,
  p.prosecdef AS is_security_definer,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_can_execute,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
  (pg_get_functiondef(p.oid) ~* '(vault\.|current_setting|api_key|secret|service_role)') AS touches_secret_terms
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND (pg_get_functiondef(p.oid) ~* '(vault\.|current_setting|api_key|secret|service_role)');

-- ============================================================================
-- 6. Public storage buckets — files in a public bucket are world-readable.
-- Expected: only buckets you intentionally made public (e.g. ad images).
-- ============================================================================
SELECT name, public, file_size_limit
FROM storage.buckets
WHERE public = true;

-- ============================================================================
-- 7. Database-webhook triggers with embedded tokens (like "Chat Translation"
-- on chat_messages). Embedding a service-role JWT here is the STANDARD
-- Supabase Database Webhooks pattern and is only readable via raw catalog
-- access (not exposed to PostgREST clients) — listed here so you know they
-- exist and can eyeball the target URLs. Value NOT printed, URL only.
-- ============================================================================
SELECT tgrelid::regclass AS on_table,
       tgname            AS trigger_name
FROM pg_trigger
WHERE NOT tgisinternal
  AND pg_get_triggerdef(t.oid) LIKE '%http_request%'
ORDER BY 1;

-- ============================================================================
-- 8. Realtime publication — the tables whose row changes are streamed to
-- subscribed clients (subject to each client's RLS visibility).
-- ============================================================================
SELECT tablename FROM pg_publication_tables
WHERE pubname = 'supabase_realtime' ORDER BY tablename;
