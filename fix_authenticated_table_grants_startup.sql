-- ============================================================================
-- fix_authenticated_table_grants_startup.sql
--
-- VERIFIED OUTCOME (diagnostic run 2026-10-23):
--   `authenticated` ALREADY held full grants (incl. DELETE/TRUNCATE/
--   REFERENCES — a pre-existing GRANT ALL) on users, user_chat_keys,
--   user_chat_key_wrappers and user_chat_crk_wrappers. The grants were never
--   the cause. The Section B grants below are kept as idempotent insurance
--   only (they also re-assert the exact privilege set if a future security
--   sweep drops table grants again — the failure mode that hit ad_*).
--
-- ACTUAL ROOT CAUSE of the two startup 42501s
-- ("permission denied for table users" in verification status, and
--  "permission denied for table user_chat_keys" in ChatKeyProvider setup):
--   the requests ran as ANON. When the Supabase SDK drops its in-memory
--   session on a failed token refresh (refresh_token_already_used race with
--   the native background service), the client falls back to the anon key,
--   and PostgREST executes the request as the `anon` role — which
--   deliberately has no SELECT on users (harden_nonmatched_user_privacy.sql)
--   and none on the chat-key tables. The errors are therefore transient
--   session-gap noise: caught, retried by the providers (30s timer /
--   connectivity resume), and self-healing once the session is restored.
--
--   The fix is app-side, already applied in lib/main.dart:
--     * the raw-SDK auth listener no longer forces a ChatKeyProvider
--       re-init on non-explicit signedOut (that re-init was the failing
--       user_chat_keys request);
--     * the bootstrap validator restores the persisted session BEFORE the
--       getUser() loop instead of validating with no session.
--   DO NOT "fix" this by granting these tables to `anon` — that revoke is
--   the deliberate privacy hardening.
--
-- All statements are idempotent. Section A remains useful as a grant/policy
-- snapshot any time a 42501 shows up on these tables.
-- ============================================================================

-- ============================================================================
-- SECTION A — diagnostics: what do the grants/policies look like right now?
-- (Output only. If `authenticated` already has SELECT here, the startup 42501s
--  came from anon-fallback during the session gap; the grants below are still
--  the correct end state.)
-- ============================================================================
SELECT grantee, string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privileges
FROM information_schema.table_privileges
WHERE table_schema = 'public'
  AND table_name IN ('users', 'user_chat_keys', 'user_chat_key_wrappers', 'user_chat_crk_wrappers')
  AND grantee IN ('anon', 'authenticated')
GROUP BY grantee, table_name
ORDER BY table_name, grantee;

SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('users', 'user_chat_keys', 'user_chat_key_wrappers', 'user_chat_crk_wrappers')
ORDER BY tablename, policyname;

-- ============================================================================
-- SECTION B — idempotent insurance: re-assert the app's table DML for
-- `authenticated` (diagnostic confirmed these grants already exist; harmless
-- no-ops today, protection if a future sweep drops table grants again).
-- RLS continues to gate every row; see policy listing above.
-- ============================================================================

-- users: the app reads the caller's own row (verification status, profile) and
-- updates it (profile sync / verification flow).
GRANT SELECT ON TABLE public.users TO authenticated;
GRANT UPDATE ON TABLE public.users TO authenticated;

-- Chat encryption keys: own-row reads/writes plus the matched-pair public-key
-- reads the chat screens perform.
GRANT SELECT, INSERT, UPDATE ON TABLE public.user_chat_keys TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.user_chat_key_wrappers TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.user_chat_crk_wrappers TO authenticated;

-- ============================================================================
-- SECTION C — re-grant EXECUTE on the chat-key RPCs the app calls
-- ( SECURITY DEFINER functions; revokes in the May sweeps hit function EXECUTE
--   en masse — see 20260506220000_security_cleanup_final_dynamic.sql )
-- ============================================================================
DO $$
DECLARE fn RECORD;
BEGIN
  FOR fn IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'create_or_replace_chat_key_wrapper',
        'replace_lost_chat_key',
        'get_peer_chat_public_keys',
        'get_user_active_chat_key'
      )
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', fn.sig);
  END LOOP;
END $$;

-- ============================================================================
-- SECTION D — verify
-- ============================================================================
SELECT grantee, privilege_type
FROM information_schema.table_privileges
WHERE table_schema = 'public'
  AND table_name IN ('users', 'user_chat_keys', 'user_chat_key_wrappers', 'user_chat_crk_wrappers')
  AND grantee = 'authenticated'
ORDER BY table_name, privilege_type;
