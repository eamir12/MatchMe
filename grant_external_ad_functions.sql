-- ============================================================================
-- Grant execute on external ad analytics functions (all overloads)
-- ============================================================================

-- admin_list_external_ad_analytics_by_platform
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_platform(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_platform(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_platform(date, date) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_platform(timestamptz, timestamptz) TO anon;

-- admin_list_external_ad_analytics_by_network
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_network(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_network(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_network(date, date) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_network(timestamptz, timestamptz) TO anon;

-- admin_list_external_ad_analytics_by_placement
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_placement(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_placement(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_placement(date, date) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_placement(timestamptz, timestamptz) TO anon;

-- admin_list_external_ad_events
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_events(uuid, text, text, date, date, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_events(uuid, text, text, date, date, integer) TO anon;

-- admin_list_external_ad_event_details
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_event_details(text, text, date, date, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_event_details(text, text, date, date, integer) TO anon;

-- Verify grants
SELECT p.proname, pg_get_function_identity_arguments(p.oid) as args, 
       pg_get_userbyid(a.grantee) as grantee, a.privilege_type
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
JOIN aclexplode(COALESCE(p.proacl, '{}'::aclitem[])) a ON true
WHERE n.nspname = 'public' 
  AND p.proname LIKE 'admin_list_external_ad%'
  AND pg_get_userbyid(a.grantee) IN ('authenticated', 'anon')
ORDER BY p.proname;