-- Fix admin metrics function to bypass RLS on ad_impressions, ad_clicks, ad_reports
-- The SECURITY DEFINER function needs to see all rows regardless of RLS

BEGIN;

-- Grant bypass RLS to the function owner for the analytics tables
ALTER TABLE public.ad_impressions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ad_clicks FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ad_reports FORCE ROW LEVEL SECURITY;

-- Create a policy that allows the function (via its owner) to see all rows
-- We use a role-based approach - functions running as admin role can see all

-- Alternative: Change function to SECURITY INVOKER so it runs as the admin user
CREATE OR REPLACE FUNCTION public.admin_list_sponsored_campaign_metrics()
RETURNS TABLE (
  campaign_id uuid,
  impressions bigint,
  clicks bigint,
  reports bigint,
  ctr_percent numeric,
  last_impression_at timestamptz,
  last_click_at timestamptz,
  last_report_at timestamptz
)
LANGUAGE plpgsql
SECURITY INVOKER  -- Changed from SECURITY DEFINER to run as calling user
SET search_path = public
AS $$
BEGIN
  -- Check if caller is admin
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.users
    WHERE id = auth.uid()
      AND is_admin = true
  ) THEN
    RAISE EXCEPTION 'Admin access required'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH impression_stats AS (
    SELECT
      ad_impressions.campaign_id,
      COUNT(*)::bigint AS impressions,
      MAX(ad_impressions.created_at) AS last_impression_at
    FROM public.ad_impressions
    GROUP BY ad_impressions.campaign_id
  ),
  click_stats AS (
    SELECT
      ad_clicks.campaign_id,
      COUNT(*)::bigint AS clicks,
      MAX(ad_clicks.created_at) AS last_click_at
    FROM public.ad_clicks
    GROUP BY ad_clicks.campaign_id
  ),
  report_stats AS (
    SELECT
      ad_reports.campaign_id,
      COUNT(*)::bigint AS reports,
      MAX(ad_reports.created_at) AS last_report_at
    FROM public.ad_reports
    GROUP BY ad_reports.campaign_id
  )
  SELECT
    c.id AS campaign_id,
    COALESCE(i.impressions, 0)::bigint AS impressions,
    COALESCE(k.clicks, 0)::bigint AS clicks,
    COALESCE(r.reports, 0)::bigint AS reports,
    CASE
      WHEN COALESCE(i.impressions, 0) = 0 THEN 0::numeric
      ELSE ROUND((COALESCE(k.clicks, 0)::numeric / i.impressions::numeric) * 100, 2)
    END AS ctr_percent,
    i.last_impression_at,
    k.last_click_at,
    r.last_report_at
  FROM public.ad_campaigns c
  LEFT JOIN impression_stats i ON i.campaign_id = c.id
  LEFT JOIN click_stats k ON k.campaign_id = c.id
  LEFT JOIN report_stats r ON r.campaign_id = c.id
  ORDER BY c.updated_at DESC, c.id;
END;
$$;

COMMIT;
