-- Add SELECT policy for authenticated users on ad_revenue_events
DROP POLICY IF EXISTS "Authenticated can read ad_revenue_events" ON public.ad_revenue_events;
CREATE POLICY "Authenticated can read ad_revenue_events" ON public.ad_revenue_events
FOR SELECT TO authenticated USING (true);

-- Also check ad_networks has SELECT for authenticated
DROP POLICY IF EXISTS "Authenticated can read ad_networks" ON public.ad_networks;
CREATE POLICY "Authenticated can read ad_networks" ON public.ad_networks
FOR SELECT TO authenticated USING (true);

-- Verify policies
SELECT tablename, policyname, cmd FROM pg_policies 
WHERE schemaname = 'public' AND tablename IN ('ad_revenue_events', 'ad_networks');