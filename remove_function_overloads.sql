-- Remove the date version, keep timestamptz version
DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_platform(date, date);
DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_network(date, date);
DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_placement(date, date);

-- Verify only one version remains
SELECT proname, pg_get_function_identity_arguments(oid) as args
FROM pg_proc 
WHERE pronamespace = 'public'::regnamespace
  AND proname LIKE 'admin_list_external_ad%'
ORDER BY proname;