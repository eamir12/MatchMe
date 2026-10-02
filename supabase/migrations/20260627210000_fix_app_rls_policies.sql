-- Re-grant SELECT + add RLS policies for tables that were revoked by
-- 20260506200000_comprehensive_security_advisor_fixes.sql but never
-- restored, causing permission denied errors in the Flutter app.

BEGIN;

-- ============================================================
-- 1. subscription_tiers — catalog table, all authenticated
--    users need to read available tiers.
-- ============================================================
GRANT SELECT ON TABLE public.subscription_tiers TO authenticated;

DROP POLICY IF EXISTS "authenticated_can_select_subscription_tiers" ON public.subscription_tiers;
CREATE POLICY "authenticated_can_select_subscription_tiers"
  ON public.subscription_tiers
  FOR SELECT
  TO authenticated
  USING (true);

-- ============================================================
-- 2. user_subscription_queue — users need to read/write their
--    own queue entries.  Existing per-user policies work as
--    soon as the table-level GRANT is restored.
-- ============================================================
GRANT SELECT ON TABLE public.user_subscription_queue TO authenticated;

-- ============================================================
-- 3. app_config — contains public app settings (feature flags,
--    default values, etc.) that authenticated clients read at
--    startup.
-- ============================================================
GRANT SELECT ON TABLE public.app_config TO authenticated;

DROP POLICY IF EXISTS "authenticated_can_select_app_config" ON public.app_config;
CREATE POLICY "authenticated_can_select_app_config"
  ON public.app_config
  FOR SELECT
  TO authenticated
  USING (true);

-- ============================================================
-- 4. users — regular (non-admin) authenticated users can read
--    their own row.  Admins are already covered by the existing
--    "Admins can read users" policy.
-- ============================================================
DROP POLICY IF EXISTS "authenticated_can_select_own_user" ON public.users;
CREATE POLICY "authenticated_can_select_own_user"
  ON public.users
  FOR SELECT
  TO authenticated
  USING (auth.uid() = id);

COMMIT;
