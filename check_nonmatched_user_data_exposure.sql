-- ============================================================================
-- check_nonmatched_user_data_exposure.sql  (READ-ONLY — safe to run)
--
-- Purpose: verify that a non-matched user cannot read another user's data
-- through the API, and whether the (now client-unused) get_potential_matches
-- RPC is still callable by end users.
--
-- Sections:
--   1. RLS enabled/forced on the sensitive tables
--   2. All RLS policies on those tables (incl. whether SELECT policies exist)
--   3. Table-level GRANTs to anon / authenticated / PUBLIC
--   4. Function privileges: can anon/authenticated/PUBLIC EXECUTE
--      get_potential_matches (and similar discovery functions)?
--   5. Exact signatures + definitions of those functions
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. RLS enabled / forced
-- ---------------------------------------------------------------------------
select
  c.relname                as table_name,
  c.relrowsecurity         as rls_enabled,
  c.relforcerowsecurity    as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('users', 'user_profiles', 'user_locations', 'user_session')
order by c.relname;

-- ---------------------------------------------------------------------------
-- 2. All RLS policies on those tables
--    NOTE: what matters most is whether a 'SELECT' (cmd = 'SELECT') policy
--    exists and what its USING clause allows. If a table has RLS enabled and
--    NO select policy, anon/authenticated cannot read any rows at all.
-- ---------------------------------------------------------------------------
select
  tablename,
  policyname,
  cmd,
  roles,
  qual               as using_expression,
  with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('users', 'user_profiles', 'user_locations', 'user_session')
order by tablename, cmd, policyname;

-- ---------------------------------------------------------------------------
-- 3. Table-level grants to anon / authenticated / PUBLIC
--    (RLS filters rows; grants decide whether the table is reachable at all)
-- ---------------------------------------------------------------------------
select
  table_name,
  grantee,
  string_agg(privilege_type, ', ' order by privilege_type) as privileges
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('users', 'user_profiles', 'user_locations', 'user_session')
  and grantee in ('anon', 'authenticated', 'PUBLIC')
group by table_name, grantee
order by table_name, grantee;

-- ---------------------------------------------------------------------------
-- 4. Can end-user roles EXECUTE the discovery functions?
--    has_function_privilege already accounts for PUBLIC grants.
--    authenticated_can_execute = true for get_potential_matches means a
--    signed-in user could still call it directly (identity + exact-location
--    exposure of non-matched users), even though no screen uses it anymore.
-- ---------------------------------------------------------------------------
select
  n.nspname                          as schema,
  p.proname                          as function_name,
  pg_get_function_identity_arguments(p.oid) as arguments,
  p.prosecdef                        as security_definer,
  has_function_privilege('anon'::regrole,          p.oid, 'EXECUTE') as anon_can_execute,
  has_function_privilege('authenticated'::regrole, p.oid, 'EXECUTE') as authenticated_can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (p.proname like '%potential%'
       or p.proname like '%nearby%'
       or p.proname like '%visible%user%')
order by p.proname;

-- ---------------------------------------------------------------------------
-- 5. Definition of get_potential_matches (shows exactly what it returns)
-- ---------------------------------------------------------------------------
select
  p.oid::regprocedure          as signature,
  pg_get_functiondef(p.oid)    as definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'get_potential_matches';
