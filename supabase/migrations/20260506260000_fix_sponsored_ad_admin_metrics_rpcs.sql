-- Add date-range parameters to sponsored-campaign analytics RPCs and
-- re-grant EXECUTE to authenticated so the admin app can call them.
-- These functions were previously no-param and had EXECUTE revoked from
-- authenticated in 20260506202000, causing 404 errors from the admin app.

BEGIN;

-- -------------------------------------------------------------------------
-- 1) admin_list_sponsored_campaign_metrics
--    SECURITY INVOKER (consistent with 20260428001000), inline admin check,
--    now accepts optional date range (defaults to last 30 days).
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_sponsored_campaign_metrics(
  p_start_date timestamp with time zone DEFAULT (now() - '30 days'::interval),
  p_end_date   timestamp with time zone DEFAULT now()
)
RETURNS TABLE (
  campaign_id       uuid,
  impressions       bigint,
  clicks            bigint,
  reports           bigint,
  ctr_percent       numeric,
  last_impression_at timestamptz,
  last_click_at     timestamptz,
  last_report_at    timestamptz
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.users WHERE id = auth.uid() AND is_admin = true
  ) THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH impression_stats AS (
    SELECT
      ad_impressions.campaign_id,
      COUNT(*)::bigint AS impressions,
      MAX(ad_impressions.created_at) AS last_impression_at
    FROM public.ad_impressions
    WHERE ad_impressions.created_at >= p_start_date
      AND ad_impressions.created_at <= p_end_date
    GROUP BY ad_impressions.campaign_id
  ),
  click_stats AS (
    SELECT
      ad_clicks.campaign_id,
      COUNT(*)::bigint AS clicks,
      MAX(ad_clicks.created_at) AS last_click_at
    FROM public.ad_clicks
    WHERE ad_clicks.created_at >= p_start_date
      AND ad_clicks.created_at <= p_end_date
    GROUP BY ad_clicks.campaign_id
  ),
  report_stats AS (
    SELECT
      ad_reports.campaign_id,
      COUNT(*)::bigint AS reports,
      MAX(ad_reports.created_at) AS last_report_at
    FROM public.ad_reports
    WHERE ad_reports.created_at >= p_start_date
      AND ad_reports.created_at <= p_end_date
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

-- -------------------------------------------------------------------------
-- 2) admin_list_sponsored_campaign_report_summaries
--    SECURITY DEFINER (uses admin_assert_is_admin), now accepts optional
--    date range (defaults to last 30 days).
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_sponsored_campaign_report_summaries(
  p_start_date timestamp with time zone DEFAULT (now() - '30 days'::interval),
  p_end_date   timestamp with time zone DEFAULT now()
)
RETURNS TABLE (
  campaign_id          uuid,
  report_count         bigint,
  unique_reporter_count bigint,
  last_reported_at     timestamptz,
  latest_reason        text,
  latest_details       text,
  latest_placement     text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.admin_assert_is_admin();

  RETURN QUERY
  WITH report_aggregates AS (
    SELECT
      r.campaign_id,
      COUNT(*)::bigint AS report_count,
      COUNT(DISTINCT r.user_id)::bigint AS unique_reporter_count,
      MAX(r.created_at) AS last_reported_at
    FROM public.ad_reports r
    WHERE r.created_at >= p_start_date
      AND r.created_at <= p_end_date
    GROUP BY r.campaign_id
  ),
  ranked_reports AS (
    SELECT
      r.campaign_id,
      r.reason,
      r.details,
      r.placement,
      ROW_NUMBER() OVER (
        PARTITION BY r.campaign_id
        ORDER BY r.created_at DESC, r.id DESC
      ) AS row_num
    FROM public.ad_reports r
    WHERE r.created_at >= p_start_date
      AND r.created_at <= p_end_date
  )
  SELECT
    aggregates.campaign_id,
    aggregates.report_count,
    aggregates.unique_reporter_count,
    aggregates.last_reported_at,
    latest.reason AS latest_reason,
    latest.details AS latest_details,
    latest.placement AS latest_placement
  FROM report_aggregates aggregates
  LEFT JOIN ranked_reports latest
    ON latest.campaign_id = aggregates.campaign_id
   AND latest.row_num = 1
  ORDER BY aggregates.last_reported_at DESC, aggregates.campaign_id;
END;
$$;

-- -------------------------------------------------------------------------
-- 3) Grant EXECUTE to authenticated so the admin app (which signs in as an
--    admin user via the anon key) can call both functions.
-- -------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_metrics(timestamp with time zone, timestamp with time zone) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_report_summaries(timestamp with time zone, timestamp with time zone) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_event_details(uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_report_details(uuid, integer) TO authenticated;

COMMIT;
