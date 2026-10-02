-- Test with ISO8601 string format (like the app sends)
SELECT * FROM public.admin_list_external_ad_analytics_by_platform(
  '2025-04-08T00:00:00.000Z',
  '2025-05-08T00:00:00.000Z'
);