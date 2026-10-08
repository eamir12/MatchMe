-- ============================================================================
-- Harden ad_revenue_events RLS.
--
-- Found during the Oct 7 ad-systems diagnostic: the policy
-- "Authenticated can read ad_revenue_events" (SELECT USING (true)) lets ANY
-- signed-in user read EVERY user's ad event rows (user_id, placement,
-- platform, timestamps, revenue). Nothing in the main app reads this table
-- directly (recording goes through SECURITY DEFINER RPCs; analytics are
-- admin-only), so this tightens it to own-rows-or-admin without breaking
-- anything. Idempotent.
-- ============================================================================

BEGIN;

DROP POLICY IF EXISTS "Authenticated can read ad_revenue_events" ON public.ad_revenue_events;

-- Users may see their own ad events (useful for future "your ad activity"
-- surfaces); admins keep full visibility via the existing admin policies.
DROP POLICY IF EXISTS "Users can read own ad_revenue_events" ON public.ad_revenue_events;

CREATE POLICY "Users can read own ad_revenue_events"
  ON public.ad_revenue_events
  FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.is_admin = true
    )
  );

COMMIT;
