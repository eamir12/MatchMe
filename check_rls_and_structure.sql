-- Check RLS status on key tables
SELECT 
  relname as table_name,
  relrowsecurity as rls_enabled
FROM pg_class
WHERE relname IN ('ad_revenue_events', 'ad_networks', 'external_ad_events', 'external_ad_analytics')
AND relkind = 'r';

-- Check all policies in public schema
SELECT tablename, policyname, cmd FROM pg_policies 
WHERE schemaname = 'public' AND tablename IN ('ad_revenue_events', 'ad_networks', 'external_ad_events', 'external_ad_analytics');