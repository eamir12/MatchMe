BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION public.set_row_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.app_config_bool(
  p_key text,
  p_default boolean
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT CASE
        WHEN jsonb_typeof(config_value) = 'boolean' THEN (config_value #>> '{}')::boolean
        WHEN jsonb_typeof(config_value) = 'string'
          THEN lower(trim(both '"' FROM config_value::text)) = 'true'
        ELSE NULL
      END
      FROM public.app_config
      WHERE config_key = p_key
      LIMIT 1
    ),
    p_default
  );
$$;

CREATE OR REPLACE FUNCTION public.user_can_receive_ads(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_tier text := 'free';
  v_expires_at timestamptz;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT
    COALESCE(NULLIF(lower(btrim(subscription_tier)), ''), 'free'),
    subscription_expires_at
  INTO v_tier, v_expires_at
  FROM public.users
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_tier = 'free' THEN
    RETURN true;
  END IF;

  IF v_expires_at IS NOT NULL AND v_expires_at <= NOW() THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;

CREATE TABLE IF NOT EXISTS public.ad_campaigns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  internal_name text NOT NULL,
  advertiser_name text NOT NULL,
  destination_url text NOT NULL,
  moderation_status text NOT NULL DEFAULT 'draft'
    CHECK (moderation_status IN ('draft', 'approved', 'rejected', 'paused')),
  family_safe boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  starts_at timestamptz NOT NULL DEFAULT NOW(),
  ends_at timestamptz,
  daily_impression_cap integer,
  total_impression_cap integer,
  sort_priority integer NOT NULL DEFAULT 100,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  approved_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  approved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT ad_campaigns_https_destination_url
    CHECK (destination_url ~* '^https://'),
  CONSTRAINT ad_campaigns_end_after_start
    CHECK (ends_at IS NULL OR ends_at > starts_at),
  CONSTRAINT ad_campaigns_daily_cap_positive
    CHECK (daily_impression_cap IS NULL OR daily_impression_cap > 0),
  CONSTRAINT ad_campaigns_total_cap_positive
    CHECK (total_impression_cap IS NULL OR total_impression_cap > 0)
);

CREATE TABLE IF NOT EXISTS public.ad_creatives (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES public.ad_campaigns(id) ON DELETE CASCADE,
  placement text NOT NULL
    CHECK (placement IN ('home_inline', 'matches_inline')),
  platform text NOT NULL
    CHECK (platform IN ('all', 'android', 'ios', 'web', 'windows', 'macos', 'linux')),
  headline_key text NOT NULL,
  body_key text,
  cta_key text,
  sponsor_name_key text,
  image_url text,
  is_active boolean NOT NULL DEFAULT true,
  sort_priority integer NOT NULL DEFAULT 100,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT ad_creatives_https_image_url
    CHECK (image_url IS NULL OR image_url ~* '^https://')
);

CREATE TABLE IF NOT EXISTS public.ad_impressions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES public.ad_campaigns(id) ON DELETE CASCADE,
  creative_id uuid NOT NULL REFERENCES public.ad_creatives(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  placement text NOT NULL,
  platform text NOT NULL,
  locale text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.ad_clicks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES public.ad_campaigns(id) ON DELETE CASCADE,
  creative_id uuid NOT NULL REFERENCES public.ad_creatives(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  placement text NOT NULL,
  platform text NOT NULL,
  locale text NOT NULL,
  destination_url text,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.ad_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES public.ad_campaigns(id) ON DELETE CASCADE,
  creative_id uuid NOT NULL REFERENCES public.ad_creatives(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  placement text NOT NULL,
  reason text NOT NULL,
  details text,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ad_campaigns_live
  ON public.ad_campaigns (is_active, moderation_status, family_safe, starts_at, ends_at, sort_priority);

CREATE INDEX IF NOT EXISTS idx_ad_creatives_lookup
  ON public.ad_creatives (placement, platform, is_active, sort_priority);

CREATE INDEX IF NOT EXISTS idx_ad_impressions_campaign_created
  ON public.ad_impressions (campaign_id, created_at);

CREATE INDEX IF NOT EXISTS idx_ad_impressions_user_created
  ON public.ad_impressions (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ad_clicks_campaign_created
  ON public.ad_clicks (campaign_id, created_at);

CREATE INDEX IF NOT EXISTS idx_ad_reports_campaign_created
  ON public.ad_reports (campaign_id, created_at DESC);

DROP TRIGGER IF EXISTS trigger_ad_campaigns_updated_at ON public.ad_campaigns;
CREATE TRIGGER trigger_ad_campaigns_updated_at
  BEFORE UPDATE ON public.ad_campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.set_row_updated_at();

DROP TRIGGER IF EXISTS trigger_ad_creatives_updated_at ON public.ad_creatives;
CREATE TRIGGER trigger_ad_creatives_updated_at
  BEFORE UPDATE ON public.ad_creatives
  FOR EACH ROW
  EXECUTE FUNCTION public.set_row_updated_at();

ALTER TABLE public.ad_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_creatives ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_impressions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_clicks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can manage ad_campaigns" ON public.ad_campaigns;
CREATE POLICY "Admins can manage ad_campaigns"
  ON public.ad_campaigns
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.users
      WHERE users.id = auth.uid()
        AND users.is_admin = true
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.users
      WHERE users.id = auth.uid()
        AND users.is_admin = true
    )
  );

DROP POLICY IF EXISTS "Admins can manage ad_creatives" ON public.ad_creatives;
CREATE POLICY "Admins can manage ad_creatives"
  ON public.ad_creatives
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.users
      WHERE users.id = auth.uid()
        AND users.is_admin = true
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.users
      WHERE users.id = auth.uid()
        AND users.is_admin = true
    )
  );

DROP POLICY IF EXISTS "Admins can manage ad_impressions" ON public.ad_impressions;
CREATE POLICY "Admins can manage ad_impressions"
  ON public.ad_impressions
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.users
      WHERE users.id = auth.uid()
        AND users.is_admin = true
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.users
      WHERE users.id = auth.uid()
        AND users.is_admin = true
    )
  );

DROP POLICY IF EXISTS "Admins can manage ad_clicks" ON public.ad_clicks;
CREATE POLICY "Admins can manage ad_clicks"
  ON public.ad_clicks
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.users
      WHERE users.id = auth.uid()
        AND users.is_admin = true
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.users
      WHERE users.id = auth.uid()
        AND users.is_admin = true
    )
  );

DROP POLICY IF EXISTS "Admins can manage ad_reports" ON public.ad_reports;
CREATE POLICY "Admins can manage ad_reports"
  ON public.ad_reports
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.users
      WHERE users.id = auth.uid()
        AND users.is_admin = true
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.users
      WHERE users.id = auth.uid()
        AND users.is_admin = true
    )
  );

CREATE OR REPLACE FUNCTION public.get_sponsored_ad_for_placement(
  p_placement text,
  p_locale text,
  p_platform text
)
RETURNS TABLE (
  campaign_id uuid,
  creative_id uuid,
  placement text,
  platform text,
  destination_url text,
  image_url text,
  sponsor_name text,
  headline text,
  body text,
  cta_label text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_locale text := lower(COALESCE(NULLIF(btrim(p_locale), ''), 'en'));
  v_platform text := lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web'));
BEGIN
  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT public.app_config_bool('ads.internal.enabled', false) THEN
    RETURN;
  END IF;

  IF NOT public.app_config_bool('ads.internal.sponsored_cards_enabled', true) THEN
    RETURN;
  END IF;

  IF NOT public.user_can_receive_ads(v_user_id) THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH eligible AS (
    SELECT
      c.id AS campaign_id,
      cr.id AS creative_id,
      cr.placement,
      cr.platform,
      c.destination_url,
      cr.image_url,
      COALESCE(sponsor_locale.value, sponsor_en.value, c.advertiser_name) AS sponsor_name,
      COALESCE(headline_locale.value, headline_en.value) AS headline,
      COALESCE(body_locale.value, body_en.value, '') AS body,
      COALESCE(cta_locale.value, cta_en.value, '') AS cta_label,
      c.daily_impression_cap,
      c.total_impression_cap,
      c.sort_priority AS campaign_sort_priority,
      cr.sort_priority AS creative_sort_priority,
      (
        SELECT COUNT(*)
        FROM public.ad_impressions i
        WHERE i.campaign_id = c.id
          AND i.created_at >= date_trunc('day', NOW())
      ) AS impressions_today,
      (
        SELECT COUNT(*)
        FROM public.ad_impressions i
        WHERE i.campaign_id = c.id
      ) AS impressions_total
    FROM public.ad_campaigns c
    INNER JOIN public.ad_creatives cr
      ON cr.campaign_id = c.id
    LEFT JOIN public.translations headline_locale
      ON headline_locale.locale = v_locale
     AND headline_locale.key = cr.headline_key
    LEFT JOIN public.translations headline_en
      ON headline_en.locale = 'en'
     AND headline_en.key = cr.headline_key
    LEFT JOIN public.translations body_locale
      ON body_locale.locale = v_locale
     AND body_locale.key = cr.body_key
    LEFT JOIN public.translations body_en
      ON body_en.locale = 'en'
     AND body_en.key = cr.body_key
    LEFT JOIN public.translations cta_locale
      ON cta_locale.locale = v_locale
     AND cta_locale.key = cr.cta_key
    LEFT JOIN public.translations cta_en
      ON cta_en.locale = 'en'
     AND cta_en.key = cr.cta_key
    LEFT JOIN public.translations sponsor_locale
      ON sponsor_locale.locale = v_locale
     AND sponsor_locale.key = cr.sponsor_name_key
    LEFT JOIN public.translations sponsor_en
      ON sponsor_en.locale = 'en'
     AND sponsor_en.key = cr.sponsor_name_key
    WHERE c.is_active = true
      AND cr.is_active = true
      AND c.family_safe = true
      AND c.moderation_status = 'approved'
      AND c.starts_at <= NOW()
      AND (c.ends_at IS NULL OR c.ends_at > NOW())
      AND cr.placement = p_placement
      AND cr.platform IN ('all', v_platform)
  )
  SELECT
    eligible.campaign_id,
    eligible.creative_id,
    eligible.placement,
    eligible.platform,
    eligible.destination_url,
    eligible.image_url,
    eligible.sponsor_name,
    eligible.headline,
    eligible.body,
    eligible.cta_label
  FROM eligible
  WHERE eligible.headline IS NOT NULL
    AND (eligible.daily_impression_cap IS NULL OR eligible.impressions_today < eligible.daily_impression_cap)
    AND (eligible.total_impression_cap IS NULL OR eligible.impressions_total < eligible.total_impression_cap)
  ORDER BY eligible.creative_sort_priority ASC, eligible.campaign_sort_priority ASC, eligible.campaign_id
  LIMIT 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_ad_impression(
  p_campaign_id uuid,
  p_creative_id uuid,
  p_placement text,
  p_platform text,
  p_locale text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_id uuid := gen_random_uuid();
BEGIN
  IF v_user_id IS NULL OR NOT public.user_can_receive_ads(v_user_id) THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.ad_impressions (
    id,
    campaign_id,
    creative_id,
    user_id,
    placement,
    platform,
    locale
  )
  VALUES (
    v_id,
    p_campaign_id,
    p_creative_id,
    v_user_id,
    p_placement,
    lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web')),
    lower(COALESCE(NULLIF(btrim(p_locale), ''), 'en'))
  );

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_ad_click(
  p_campaign_id uuid,
  p_creative_id uuid,
  p_placement text,
  p_platform text,
  p_locale text,
  p_destination_url text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_id uuid := gen_random_uuid();
BEGIN
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.ad_clicks (
    id,
    campaign_id,
    creative_id,
    user_id,
    placement,
    platform,
    locale,
    destination_url
  )
  VALUES (
    v_id,
    p_campaign_id,
    p_creative_id,
    v_user_id,
    p_placement,
    lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web')),
    lower(COALESCE(NULLIF(btrim(p_locale), ''), 'en')),
    p_destination_url
  );

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.report_ad(
  p_campaign_id uuid,
  p_creative_id uuid,
  p_placement text,
  p_reason text,
  p_details text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_id uuid := gen_random_uuid();
BEGIN
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.ad_reports (
    id,
    campaign_id,
    creative_id,
    user_id,
    placement,
    reason,
    details
  )
  VALUES (
    v_id,
    p_campaign_id,
    p_creative_id,
    v_user_id,
    p_placement,
    COALESCE(NULLIF(btrim(p_reason), ''), 'user_reported'),
    NULLIF(btrim(COALESCE(p_details, '')), '')
  );

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.get_sponsored_ad_for_placement(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_ad_impression(uuid, uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_ad_click(uuid, uuid, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.report_ad(uuid, uuid, text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_sponsored_ad_for_placement(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_impression(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_click(uuid, uuid, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_ad(uuid, uuid, text, text, text) TO authenticated;

INSERT INTO public.app_config (
  config_key,
  config_value,
  config_type,
  category,
  description,
  is_user_configurable,
  min_value,
  max_value
) VALUES
  (
    'ads.internal.enabled',
    'false'::jsonb,
    'boolean',
    'ads',
    'Global kill switch for internal advertising features.',
    false,
    null,
    null
  ),
  (
    'ads.internal.free_tier_only',
    'true'::jsonb,
    'boolean',
    'ads',
    'When enabled, only users on the free tier can receive internal ads.',
    false,
    null,
    null
  ),
  (
    'ads.internal.family_safe_only',
    'true'::jsonb,
    'boolean',
    'ads',
    'When enabled, the app only serves family-safe approved internal campaigns.',
    false,
    null,
    null
  ),
  (
    'ads.internal.sponsored_cards_enabled',
    'true'::jsonb,
    'boolean',
    'ads',
    'Controls whether Supabase-managed sponsored cards can be shown.',
    false,
    null,
    null
  ),
  (
    'ads.internal.mobile.native_enabled',
    'false'::jsonb,
    'boolean',
    'ads',
    'Controls whether mobile native-network ads are enabled.',
    false,
    null,
    null
  ),
  (
    'ads.internal.mobile.provider',
    '"none"'::jsonb,
    'string',
    'ads',
    'Mobile ad provider identifier. Reserved for future native SDK integration.',
    false,
    null,
    null
  ),
  (
    'ads.internal.allowed_placements',
    '["home_inline", "matches_inline"]'::jsonb,
    'array',
    'ads',
    'Placements where internal ads may be shown.',
    false,
    null,
    null
  ),
  (
    'ads.internal.max_impressions_per_session',
    '3'::jsonb,
    'number',
    'ads',
    'Maximum sponsored impressions allowed during a single app session.',
    false,
    0,
    20
  ),
  (
    'ads.internal.min_minutes_between_impressions',
    '8'::jsonb,
    'number',
    'ads',
    'Minimum pacing time between ad impressions for the same app session.',
    false,
    0,
    120
  ),
  (
    'ads.internal.first_impression_delay_seconds',
    '90'::jsonb,
    'number',
    'ads',
    'Minimum delay after app start before the first ad can appear.',
    false,
    0,
    1800
  ),
  (
    'ads.internal.report_enabled',
    'true'::jsonb,
    'boolean',
    'ads',
    'Controls whether users can report a sponsored card.',
    false,
    null,
    null
  )
ON CONFLICT (config_key) DO UPDATE
SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

COMMENT ON TABLE public.ad_campaigns IS 'Moderated advertising campaigns used for family-safe sponsored content.';
COMMENT ON TABLE public.ad_creatives IS 'Placement and platform-specific sponsored creative definitions backed by translations.';
COMMENT ON TABLE public.ad_impressions IS 'Audit trail for sponsored content impressions.';
COMMENT ON TABLE public.ad_clicks IS 'Audit trail for sponsored content clicks.';
COMMENT ON TABLE public.ad_reports IS 'User-submitted reports for sponsored content moderation review.';

COMMIT;
