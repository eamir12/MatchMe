-- =============================================================================
-- Ad Analytics Function Updates
-- -----------------------------------------------------------------------------
-- Purpose: Add date-range support + last-event timestamps to the ad analytics
-- RPCs used by the admin ad dashboards.
--
-- HOW TO USE:
--   1. Run Section A below (the EXTERNAL platform function) — this one is
--      ready to run as-is; it is based on the current function definition.
--   2. BEFORE running Section B (the INTERNAL functions), run the two
--      "inspector" queries at the bottom to get the CURRENT bodies of:
--        - admin_list_sponsored_campaign_metrics
--        - admin_list_sponsored_campaign_report_summaries
--      Paste them back so the CREATE OR REPLACE can match the real
--      table/column names exactly (Section B below is a TEMPLATE that assumes
--      the standard ad_impressions / ad_clicks / ad_reports layout).
-- =============================================================================


-- =============================================================================
-- SECTION A — EXTERNAL ADS: add last_impression_at / last_click_at columns
-- =============================================================================
-- This is the function confirmed in the live DB. The ONLY changes vs. the
-- current version are the two added MAX(...) output columns. Date params
-- already exist (p_start_date / p_end_date with 30-day default) and are kept.
-- Safe to run as-is.

CREATE OR REPLACE FUNCTION public.admin_list_external_ad_analytics_by_platform(
  p_start_date timestamp with time zone DEFAULT (now() - '30 days'::interval),
  p_end_date timestamp with time zone DEFAULT now()
)
RETURNS TABLE(
  platform text,
  impressions bigint,
  clicks bigint,
  revenue_usd numeric,
  ctr_percent numeric,
  cpm numeric,
  last_impression_at timestamp with time zone,
  last_click_at timestamp with time zone
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    COALESCE(platform, 'unknown') as platform,
    COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0)::bigint AS impressions,
    (
      COALESCE(SUM(CASE WHEN event_type = 'impression' THEN click_count ELSE 0 END), 0) +
      COALESCE(SUM(CASE WHEN event_type = 'click' THEN 1 ELSE 0 END), 0)
    )::bigint AS clicks,
    COALESCE(SUM(revenue_usd), 0)::numeric AS revenue_usd,
    CASE
      WHEN COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0) > 0
      THEN (
        (COALESCE(SUM(CASE WHEN event_type = 'impression' THEN click_count ELSE 0 END), 0) +
         COALESCE(SUM(CASE WHEN event_type = 'click' THEN 1 ELSE 0 END), 0))::numeric /
        COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0)::numeric * 100
      )
      ELSE 0
    END::numeric AS ctr_percent,
    CASE
      WHEN COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0) > 0
      THEN (COALESCE(SUM(revenue_usd), 0)::numeric /
            COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0)::numeric * 1000)
      ELSE 0
    END::numeric AS cpm,
    -- NEW: timestamp of the most recent impression in the window
    MAX(CASE WHEN event_type = 'impression' THEN created_at END) AS last_impression_at,
    -- NEW: timestamp of the most recent click in the window
    MAX(CASE WHEN event_type = 'click' THEN created_at END) AS last_click_at
  FROM public.ad_revenue_events
  WHERE event_type IN ('impression', 'click')
    AND created_at >= p_start_date
    AND created_at <= p_end_date
  GROUP BY platform
  ORDER BY COUNT(*) DESC;
$function$;

-- Grant execute to authenticated/admin roles (match whatever exists today;
-- these GRANTs are harmless if already present).
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_platform(timestamp with time zone, timestamp with time zone) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_platform(timestamp with time zone, timestamp with time zone) TO anon;


-- =============================================================================
-- SECTION B — INTERNAL (SPONSORED) ADS: TEMPLATE — REVIEW BEFORE RUNNING
-- =============================================================================
-- These functions currently take NO parameters. The templates below add the
-- same optional date params + last-event timestamps. They assume the standard
-- layout:
--   ad_impressions(campaign_id, created_at, ...)
--   ad_clicks(campaign_id, created_at, ...)
--   ad_reports(campaign_id, created_at, ...)
-- >>> RUN THE INSPECTOR QUERIES AT THE BOTTOM FIRST and confirm the table/
-- >>> column names match. If they differ, send the output back before running.

-- ---- B1: per-campaign impression/click metrics + last-event timestamps ----
CREATE OR REPLACE FUNCTION public.admin_list_sponsored_campaign_metrics(
  p_start_date timestamp with time zone DEFAULT (now() - '30 days'::interval),
  p_end_date timestamp with time zone DEFAULT now()
)
RETURNS TABLE(
  campaign_id text,
  impressions bigint,
  clicks bigint,
  reports bigint,
  ctr_percent numeric,
  last_impression_at timestamp with time zone,
  last_click_at timestamp with time zone
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    COALESCE(c.campaign_id, 'unknown') AS campaign_id,
    COALESCE(SUM(CASE WHEN c.event_type = 'impression' THEN 1 ELSE 0 END), 0)::bigint AS impressions,
    COALESCE(SUM(CASE WHEN c.event_type = 'click' THEN 1 ELSE 0 END), 0)::bigint AS clicks,
    0::bigint AS reports,
    CASE
      WHEN COALESCE(SUM(CASE WHEN c.event_type = 'impression' THEN 1 ELSE 0 END), 0) > 0
      THEN (COALESCE(SUM(CASE WHEN c.event_type = 'click' THEN 1 ELSE 0 END), 0)::numeric /
            COALESCE(SUM(CASE WHEN c.event_type = 'impression' THEN 1 ELSE 0 END), 0)::numeric * 100)
      ELSE 0
    END::numeric AS ctr_percent,
    MAX(CASE WHEN c.event_type = 'impression' THEN c.created_at END) AS last_impression_at,
    MAX(CASE WHEN c.event_type = 'click' THEN c.created_at END) AS last_click_at
  FROM (
    SELECT campaign_id, created_at, 'impression'::text AS event_type FROM public.ad_impressions
    WHERE created_at >= p_start_date AND created_at <= p_end_date
    UNION ALL
    SELECT campaign_id, created_at, 'click'::text AS event_type FROM public.ad_clicks
    WHERE created_at >= p_start_date AND created_at <= p_end_date
  ) c
  GROUP BY c.campaign_id;
$function$;

-- ---- B2: per-campaign report summaries (date-filtered) ----
CREATE OR REPLACE FUNCTION public.admin_list_sponsored_campaign_report_summaries(
  p_start_date timestamp with time zone DEFAULT (now() - '30 days'::interval),
  p_end_date timestamp with time zone DEFAULT now()
)
RETURNS TABLE(
  campaign_id text,
  report_count bigint,
  unique_reporter_count bigint,
  last_reported_at timestamp with time zone,
  latest_reason text,
  latest_details text,
  latest_placement text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    campaign_id,
    COUNT(*)::bigint AS report_count,
    COUNT(DISTINCT reporter_user_id)::bigint AS unique_reporter_count,
    MAX(created_at) AS last_reported_at,
    (array_agg(reason ORDER BY created_at DESC))[1] AS latest_reason,
    (array_agg(details ORDER BY created_at DESC))[1] AS latest_details,
    (array_agg(placement ORDER BY created_at DESC))[1] AS latest_placement
  FROM public.ad_reports
  WHERE created_at >= p_start_date AND created_at <= p_end_date
  GROUP BY campaign_id;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_metrics(timestamp with time zone, timestamp with time zone) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_metrics(timestamp with time zone, timestamp with time zone) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_report_summaries(timestamp with time zone, timestamp with time zone) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_report_summaries(timestamp with time zone, timestamp with time zone) TO anon;


-- =============================================================================
-- INSPECTOR QUERIES — run these first and send the output back so Section B
-- can be finalized to match the real table/column names.
-- =============================================================================
-- SELECT pg_get_functiondef(oid)
-- FROM pg_proc
-- WHERE proname = 'admin_list_sponsored_campaign_metrics';
--
-- SELECT pg_get_functiondef(oid)
-- FROM pg_proc
-- WHERE proname = 'admin_list_sponsored_campaign_report_summaries';
