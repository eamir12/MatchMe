BEGIN;

-- Create ad_networks table for managing external ad providers
CREATE TABLE IF NOT EXISTS public.ad_networks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL UNIQUE CHECK (provider IN ('admob', 'facebook', 'applovin', 'unity')),
  display_name text NOT NULL,
  is_enabled boolean NOT NULL DEFAULT false,
  priority integer NOT NULL DEFAULT 100,
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

-- Create ad_units table for network-specific placements
CREATE TABLE IF NOT EXISTS public.ad_units (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  network_id uuid NOT NULL REFERENCES public.ad_networks(id) ON DELETE CASCADE,
  placement text NOT NULL,
  platform text NOT NULL CHECK (platform IN ('android', 'ios', 'web')),
  ad_unit_id text NOT NULL,
  ad_format text NOT NULL CHECK (ad_format IN ('banner', 'interstitial', 'rewarded', 'native')),
  is_active boolean NOT NULL DEFAULT true,
  priority integer NOT NULL DEFAULT 100,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE(network_id, placement, platform, ad_format)
);

-- Create ad_revenue_events table for earnings tracking
CREATE TABLE IF NOT EXISTS public.ad_revenue_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  network_id uuid NOT NULL REFERENCES public.ad_networks(id) ON DELETE CASCADE,
  ad_unit_id uuid NOT NULL REFERENCES public.ad_units(id) ON DELETE CASCADE,
  placement text NOT NULL,
  platform text NOT NULL,
  event_type text NOT NULL CHECK (event_type IN ('impression', 'click', 'conversion')),
  revenue_usd numeric(10, 6) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  ad_format text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

-- Create ad_network_analytics table for aggregated metrics
CREATE TABLE IF NOT EXISTS public.ad_network_analytics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  network_id uuid NOT NULL REFERENCES public.ad_networks(id) ON DELETE CASCADE,
  date date NOT NULL,
  placement text NOT NULL,
  platform text NOT NULL,
  impressions integer NOT NULL DEFAULT 0,
  clicks integer NOT NULL DEFAULT 0,
  conversions integer NOT NULL DEFAULT 0,
  revenue_usd numeric(12, 2) NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE(network_id, date, placement, platform)
);

-- Create ad_consent table for user privacy preferences
CREATE TABLE IF NOT EXISTS public.ad_consent (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  personalized_ads boolean NOT NULL DEFAULT false,
  non_personalized_ads boolean NOT NULL DEFAULT true,
  consent_given_at timestamptz NOT NULL DEFAULT NOW(),
  consent_version text NOT NULL DEFAULT '1.0',
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_ad_networks_enabled
  ON public.ad_networks (is_enabled, priority);

CREATE INDEX IF NOT EXISTS idx_ad_units_lookup
  ON public.ad_units (network_id, placement, platform, ad_format, is_active);

CREATE INDEX IF NOT EXISTS idx_ad_revenue_events_user_created
  ON public.ad_revenue_events (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ad_revenue_events_network_created
  ON public.ad_revenue_events (network_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ad_revenue_events_placement_created
  ON public.ad_revenue_events (placement, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ad_network_analytics_date
  ON public.ad_network_analytics (network_id, date DESC);

CREATE INDEX IF NOT EXISTS idx_ad_consent_user
  ON public.ad_consent (user_id);

-- Create triggers for updated_at
DROP TRIGGER IF EXISTS trigger_ad_networks_updated_at ON public.ad_networks;
CREATE TRIGGER trigger_ad_networks_updated_at
  BEFORE UPDATE ON public.ad_networks
  FOR EACH ROW
  EXECUTE FUNCTION public.set_row_updated_at();

DROP TRIGGER IF EXISTS trigger_ad_units_updated_at ON public.ad_units;
CREATE TRIGGER trigger_ad_units_updated_at
  BEFORE UPDATE ON public.ad_units
  FOR EACH ROW
  EXECUTE FUNCTION public.set_row_updated_at();

DROP TRIGGER IF EXISTS trigger_ad_network_analytics_updated_at ON public.ad_network_analytics;
CREATE TRIGGER trigger_ad_network_analytics_updated_at
  BEFORE UPDATE ON public.ad_network_analytics
  FOR EACH ROW
  EXECUTE FUNCTION public.set_row_updated_at();

DROP TRIGGER IF EXISTS trigger_ad_consent_updated_at ON public.ad_consent;
CREATE TRIGGER trigger_ad_consent_updated_at
  BEFORE UPDATE ON public.ad_consent
  FOR EACH ROW
  EXECUTE FUNCTION public.set_row_updated_at();

-- Enable RLS
ALTER TABLE public.ad_networks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_units ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_revenue_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_network_analytics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_consent ENABLE ROW LEVEL SECURITY;

-- RLS Policies for ad_networks (admins only)
DROP POLICY IF EXISTS "Admins can manage ad_networks" ON public.ad_networks;
CREATE POLICY "Admins can manage ad_networks"
  ON public.ad_networks
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

-- RLS Policies for ad_units (admins only)
DROP POLICY IF EXISTS "Admins can manage ad_units" ON public.ad_units;
CREATE POLICY "Admins can manage ad_units"
  ON public.ad_units
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

-- RLS Policies for ad_revenue_events (admins only)
DROP POLICY IF EXISTS "Admins can manage ad_revenue_events" ON public.ad_revenue_events;
CREATE POLICY "Admins can manage ad_revenue_events"
  ON public.ad_revenue_events
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

-- RLS Policies for ad_network_analytics (admins only)
DROP POLICY IF EXISTS "Admins can manage ad_network_analytics" ON public.ad_network_analytics;
CREATE POLICY "Admins can manage ad_network_analytics"
  ON public.ad_network_analytics
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

-- RLS Policies for ad_consent (users can read/write their own)
DROP POLICY IF EXISTS "Users can read their own ad_consent" ON public.ad_consent;
CREATE POLICY "Users can read their own ad_consent"
  ON public.ad_consent
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can update their own ad_consent" ON public.ad_consent;
CREATE POLICY "Users can update their own ad_consent"
  ON public.ad_consent
  FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can insert their own ad_consent" ON public.ad_consent;
CREATE POLICY "Users can insert their own ad_consent"
  ON public.ad_consent
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "Admins can read all ad_consent" ON public.ad_consent;
CREATE POLICY "Admins can read all ad_consent"
  ON public.ad_consent
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.users
      WHERE users.id = auth.uid()
        AND users.is_admin = true
    )
  );

-- RPC: Get external ad for placement with mediation
CREATE OR REPLACE FUNCTION public.get_external_ad_for_placement(
  p_placement text,
  p_platform text
)
RETURNS TABLE (
  network_id uuid,
  ad_unit_id uuid,
  placement text,
  platform text,
  ad_format text,
  ad_unit_id_external text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_platform text := lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web'));
BEGIN
  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT public.app_config_bool('ads.external.enabled', false) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    n.id,
    u.id,
    u.placement,
    u.platform,
    u.ad_format,
    u.ad_unit_id
  FROM public.ad_networks n
  INNER JOIN public.ad_units u ON u.network_id = n.id
  WHERE n.is_enabled = true
    AND u.is_active = true
    AND u.placement = p_placement
    AND u.platform IN ('web', v_platform)
  ORDER BY n.priority ASC, u.priority ASC
  LIMIT 1;
END;
$$;

-- RPC: Record external ad impression
CREATE OR REPLACE FUNCTION public.record_external_ad_impression(
  p_network_id uuid,
  p_ad_unit_id uuid,
  p_placement text,
  p_platform text,
  p_ad_format text
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

  INSERT INTO public.ad_revenue_events (
    id,
    user_id,
    network_id,
    ad_unit_id,
    placement,
    platform,
    event_type,
    ad_format
  )
  VALUES (
    v_id,
    v_user_id,
    p_network_id,
    p_ad_unit_id,
    p_placement,
    lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web')),
    'impression',
    p_ad_format
  );

  RETURN v_id;
END;
$$;

-- RPC: Record external ad click
CREATE OR REPLACE FUNCTION public.record_external_ad_click(
  p_network_id uuid,
  p_ad_unit_id uuid,
  p_placement text,
  p_platform text,
  p_ad_format text
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

  INSERT INTO public.ad_revenue_events (
    id,
    user_id,
    network_id,
    ad_unit_id,
    placement,
    platform,
    event_type,
    ad_format
  )
  VALUES (
    v_id,
    v_user_id,
    p_network_id,
    p_ad_unit_id,
    p_placement,
    lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web')),
    'click',
    p_ad_format
  );

  RETURN v_id;
END;
$$;

-- RPC: Record ad revenue (for server-side revenue tracking)
CREATE OR REPLACE FUNCTION public.record_ad_revenue(
  p_user_id uuid,
  p_network_id uuid,
  p_ad_unit_id uuid,
  p_placement text,
  p_platform text,
  p_event_type text,
  p_revenue_usd numeric,
  p_ad_format text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid := gen_random_uuid();
BEGIN
  -- Only service role or admins can record revenue
  IF auth.uid() IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.ad_revenue_events (
    id,
    user_id,
    network_id,
    ad_unit_id,
    placement,
    platform,
    event_type,
    revenue_usd,
    ad_format
  )
  VALUES (
    v_id,
    p_user_id,
    p_network_id,
    p_ad_unit_id,
    p_placement,
    lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web')),
    p_event_type,
    p_revenue_usd,
    p_ad_format
  );

  RETURN v_id;
END;
$$;

-- RPC: Get user ad consent
CREATE OR REPLACE FUNCTION public.get_user_ad_consent(p_user_id uuid)
RETURNS TABLE (
  user_id uuid,
  personalized_ads boolean,
  non_personalized_ads boolean,
  consent_given_at timestamptz,
  consent_version text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    ac.user_id,
    ac.personalized_ads,
    ac.non_personalized_ads,
    ac.consent_given_at,
    ac.consent_version
  FROM public.ad_consent ac
  WHERE ac.user_id = p_user_id;
END;
$$;

-- RPC: Update user ad consent
CREATE OR REPLACE FUNCTION public.update_user_ad_consent(
  p_personalized_ads boolean,
  p_non_personalized_ads boolean
)
RETURNS TABLE (
  user_id uuid,
  personalized_ads boolean,
  non_personalized_ads boolean,
  consent_given_at timestamptz,
  consent_version text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.ad_consent (
    user_id,
    personalized_ads,
    non_personalized_ads,
    consent_version
  )
  VALUES (
    v_user_id,
    p_personalized_ads,
    p_non_personalized_ads,
    '1.0'
  )
  ON CONFLICT (user_id) DO UPDATE SET
    personalized_ads = EXCLUDED.personalized_ads,
    non_personalized_ads = EXCLUDED.non_personalized_ads,
    updated_at = NOW();

  RETURN QUERY
  SELECT
    ac.user_id,
    ac.personalized_ads,
    ac.non_personalized_ads,
    ac.consent_given_at,
    ac.consent_version
  FROM public.ad_consent ac
  WHERE ac.user_id = v_user_id;
END;
$$;

-- RPC: Get ad network analytics
CREATE OR REPLACE FUNCTION public.get_ad_network_analytics(
  p_network_id uuid,
  p_start_date date,
  p_end_date date
)
RETURNS TABLE (
  date date,
  placement text,
  platform text,
  impressions integer,
  clicks integer,
  conversions integer,
  revenue_usd numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid() AND is_admin = true
  ) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    ana.date,
    ana.placement,
    ana.platform,
    ana.impressions,
    ana.clicks,
    ana.conversions,
    ana.revenue_usd
  FROM public.ad_network_analytics ana
  WHERE ana.network_id = p_network_id
    AND ana.date >= p_start_date
    AND ana.date <= p_end_date
  ORDER BY ana.date DESC;
END;
$$;

-- Grant permissions
REVOKE ALL ON FUNCTION public.get_external_ad_for_placement(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_external_ad_impression(uuid, uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_external_ad_click(uuid, uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_ad_revenue(uuid, uuid, uuid, text, text, text, numeric, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_user_ad_consent(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_user_ad_consent(boolean, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_ad_network_analytics(uuid, date, date) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_external_ad_for_placement(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_external_ad_impression(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_external_ad_click(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_revenue(uuid, uuid, uuid, text, text, text, numeric, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_user_ad_consent(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_ad_consent(boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_ad_network_analytics(uuid, date, date) TO authenticated;

-- Add app_config entries for external ads
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
    'ads.external_enabled',
    'false'::jsonb,
    'boolean',
    'ads',
    'Enable external ad networks (AdMob, Facebook, etc.)',
    false,
    null,
    null
  ),
  (
    'ads.external.admob_enabled',
    'false'::jsonb,
    'boolean',
    'ads',
    'Enable Google AdMob integration',
    false,
    null,
    null
  ),
  (
    'ads.external.mediation_enabled',
    'false'::jsonb,
    'boolean',
    'ads',
    'Enable ad mediation across multiple networks',
    false,
    null,
    null
  ),
  (
    'ads.external.personalized_ads_default',
    'false'::jsonb,
    'boolean',
    'ads',
    'Default personalization setting for new users',
    false,
    null,
    null
  ),
  (
    'ads.external.show_consent_form',
    'true'::jsonb,
    'boolean',
    'ads',
    'Show consent form to users on first app launch',
    false,
    null,
    null
  ),
  (
    'ads.external.min_user_age_for_personalization',
    '13'::jsonb,
    'number',
    'ads',
    'Minimum age for personalized ads (COPPA compliance)',
    false,
    0,
    18
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

-- Add table comments
COMMENT ON TABLE public.ad_networks IS 'External ad network providers (AdMob, Facebook, AppLovin, Unity).';
COMMENT ON TABLE public.ad_units IS 'Ad unit configurations for each network, placement, platform, and format combination.';
COMMENT ON TABLE public.ad_revenue_events IS 'Audit trail for external ad impressions, clicks, and revenue events.';
COMMENT ON TABLE public.ad_network_analytics IS 'Aggregated daily analytics for external ad networks.';
COMMENT ON TABLE public.ad_consent IS 'User consent preferences for personalized vs non-personalized ads.';

COMMIT;
