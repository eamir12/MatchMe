BEGIN;

INSERT INTO storage.buckets (id, name, public)
VALUES ('sponsored-ad-images', 'sponsored-ad-images', true)
ON CONFLICT (id) DO NOTHING;

UPDATE storage.buckets
SET public = true
WHERE id = 'sponsored-ad-images';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'storage'
      AND table_name = 'buckets'
      AND column_name = 'file_size_limit'
  ) THEN
    UPDATE storage.buckets
    SET file_size_limit = 10485760
    WHERE id = 'sponsored-ad-images';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'storage'
      AND table_name = 'buckets'
      AND column_name = 'allowed_mime_types'
  ) THEN
    UPDATE storage.buckets
    SET allowed_mime_types = ARRAY[
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/gif'
    ]
    WHERE id = 'sponsored-ad-images';
  END IF;
END $$;

DROP POLICY IF EXISTS "Admins can view sponsored ad images" ON storage.objects;
DROP POLICY IF EXISTS "Admins can upload sponsored ad images" ON storage.objects;
DROP POLICY IF EXISTS "Admins can update sponsored ad images" ON storage.objects;
DROP POLICY IF EXISTS "Admins can delete sponsored ad images" ON storage.objects;

CREATE POLICY "Admins can view sponsored ad images"
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'sponsored-ad-images'
  AND EXISTS (
    SELECT 1
    FROM public.users
    WHERE users.id = auth.uid()
      AND users.is_admin = true
  )
);

CREATE POLICY "Admins can upload sponsored ad images"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'sponsored-ad-images'
  AND EXISTS (
    SELECT 1
    FROM public.users
    WHERE users.id = auth.uid()
      AND users.is_admin = true
  )
);

CREATE POLICY "Admins can update sponsored ad images"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'sponsored-ad-images'
  AND EXISTS (
    SELECT 1
    FROM public.users
    WHERE users.id = auth.uid()
      AND users.is_admin = true
  )
)
WITH CHECK (
  bucket_id = 'sponsored-ad-images'
  AND EXISTS (
    SELECT 1
    FROM public.users
    WHERE users.id = auth.uid()
      AND users.is_admin = true
  )
);

CREATE POLICY "Admins can delete sponsored ad images"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'sponsored-ad-images'
  AND EXISTS (
    SELECT 1
    FROM public.users
    WHERE users.id = auth.uid()
      AND users.is_admin = true
  )
);

CREATE OR REPLACE FUNCTION public.admin_assert_is_admin()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.users
    WHERE id = auth.uid()
      AND is_admin = true
  ) THEN
    RAISE EXCEPTION 'Admin access required'
      USING ERRCODE = '42501';
  END IF;
END;
$$;

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
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.admin_assert_is_admin();

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

CREATE OR REPLACE FUNCTION public.admin_list_recent_sponsored_ad_reports(
  p_limit integer DEFAULT 25
)
RETURNS TABLE (
  report_id uuid,
  campaign_id uuid,
  creative_id uuid,
  internal_name text,
  advertiser_name text,
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
    c.internal_name,
    c.advertiser_name,
    r.placement,
    r.reason,
    r.details,
    r.created_at
  FROM public.ad_reports r
  INNER JOIN public.ad_campaigns c
    ON c.id = r.campaign_id
  ORDER BY r.created_at DESC
  LIMIT GREATEST(COALESCE(p_limit, 25), 1);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_assert_is_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_sponsored_campaign_metrics() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_recent_sponsored_ad_reports(integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_assert_is_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_metrics() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_recent_sponsored_ad_reports(integer) TO authenticated;

COMMIT;
