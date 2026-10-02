-- Test the external ad analytics function
SELECT * FROM public.admin_list_external_ad_analytics_by_platform(
  CURRENT_DATE - INTERVAL '30 days',
  CURRENT_DATE
);