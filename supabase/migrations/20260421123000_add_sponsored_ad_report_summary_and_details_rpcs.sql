BEGIN;

CREATE OR REPLACE FUNCTION public.admin_list_sponsored_campaign_report_summaries()
RETURNS TABLE (
  campaign_id uuid,
  report_count bigint,
  unique_reporter_count bigint,
  last_reported_at timestamptz,
  latest_reason text,
  latest_details text,
  latest_placement text
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

CREATE OR REPLACE FUNCTION public.admin_list_sponsored_campaign_report_details(
  p_campaign_id uuid,
  p_limit integer DEFAULT 200
)
RETURNS TABLE (
  report_id uuid,
  campaign_id uuid,
  creative_id uuid,
  reporter_user_id uuid,
  reporter_name text,
  placement text,
  reason text,
  details text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.admin_assert_is_admin();

  RETURN QUERY
  SELECT
    r.id AS report_id,
    r.campaign_id,
    r.creative_id,
    r.user_id AS reporter_user_id,
    COALESCE(NULLIF(BTRIM(u.name), ''), r.user_id::text) AS reporter_name,
    r.placement,
    r.reason,
    r.details,
    r.created_at
  FROM public.ad_reports r
  LEFT JOIN public.users u
    ON u.id = r.user_id
  WHERE r.campaign_id = p_campaign_id
  ORDER BY r.created_at DESC, r.id DESC
  LIMIT GREATEST(COALESCE(p_limit, 200), 1);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_sponsored_campaign_report_summaries() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_sponsored_campaign_report_details(uuid, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_report_summaries() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_report_details(uuid, integer) TO authenticated;

COMMIT;
