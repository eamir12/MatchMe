-- ============================================================================
-- Follow-up inspection queries (read-only) for the Oct 7 secret-leak audit.
-- These close out the three items the main audit could not fully resolve:
-- pg_db_role_setting contents, passkey_credentials policy scope, and the
-- webhook trigger listing (fixed query).
-- ============================================================================

-- 1. The 11 db/role settings — check none embeds a secret (the Jan-2026
-- migration suggested ALTER DATABASE .. SET deepl_api_key; both known keys
-- came back NULL, but eyeball every setconfig value here).
SELECT
  setdatabase::regclass                                            AS database_oid,
  COALESCE(rolname, '(all roles)')                                 AS role_name,
  setconfig                                                        AS settings
FROM pg_db_role_setting s
LEFT JOIN pg_roles r ON r.oid = s.setrole
ORDER BY 1, 2;

-- 2. passkey_credentials — who can SELECT whose rows? If the policy is
-- "own rows only", fine. If it's USING (true), clients can enumerate other
-- users' credential IDs (not a key leak, but worth tightening).
SELECT policyname, cmd, roles, qual AS using_clause
FROM pg_policies
WHERE tablename = 'passkey_credentials';

-- Same check for the other tables the audit flagged with open policies:
SELECT tablename, policyname, cmd, roles, qual AS using_clause
FROM pg_policies
WHERE tablename IN ('notification_queue', 'user_session', 'intents', 'interests',
                    'admin_broadcast_deliveries', 'ai_quota_status', 'ai_quota_alert_state')
ORDER BY tablename, policyname;

-- 3. Database-webhook triggers (fixed query) — each embeds a service-role
-- JWT by design (standard Supabase Database Webhooks pattern; visible only
-- via raw catalog access, never to PostgREST clients). Value NOT printed.
SELECT t.tgrelid::regclass AS on_table,
       t.tgname            AS trigger_name
FROM pg_trigger t
WHERE NOT t.tgisinternal
  AND pg_get_triggerdef(t.oid) LIKE '%http_request%'
ORDER BY 1;

-- 4. Confirm the remediation took effect (run AFTER migration
-- 20262099000600): no anon policy left on app_config, no edge_internal_secret
-- row, and the new table denies clients.
SELECT policyname, roles FROM pg_policies
WHERE tablename = 'app_config' AND cmd IN ('SELECT', 'ALL');

SELECT count(*) AS edge_secret_rows_left_in_app_config
FROM public.app_config WHERE config_key = 'edge_internal_secret';

SELECT has_table_privilege('anon', 'public.edge_internal_secrets', 'SELECT')        AS anon_can_read,
       has_table_privilege('authenticated', 'public.edge_internal_secrets', 'SELECT') AS auth_can_read;
