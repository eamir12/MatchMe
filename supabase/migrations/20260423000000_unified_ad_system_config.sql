BEGIN;

-- Create unified ad system configuration table
CREATE TABLE IF NOT EXISTS public.ad_system_config (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  system_type text NOT NULL CHECK (system_type IN ('internal', 'external')),
  is_enabled boolean NOT NULL DEFAULT false,
  priority integer NOT NULL DEFAULT 100,
  
  -- Shared configuration
  allowed_placements jsonb NOT NULL DEFAULT '["home_inline", "matches_inline", "chats_inline", "events_inline"]'::jsonb,
  allowed_tiers jsonb NOT NULL DEFAULT '["free"]'::jsonb,
  allowed_platforms jsonb NOT NULL DEFAULT '["android", "ios", "web"]'::jsonb,
  
  -- Schedule configuration
  schedule_enabled boolean NOT NULL DEFAULT false,
  schedule_start_time text, -- HH:MM format
  schedule_end_time text,   -- HH:MM format
  schedule_days jsonb NOT NULL DEFAULT '["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]'::jsonb,
  
  -- Rate limiting
  max_impressions_per_session integer,
  min_minutes_between_impressions integer,
  first_impression_delay_seconds integer,
  daily_impression_cap integer,
  
  -- System-specific config
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  
  UNIQUE(system_type)
);

-- Create ad system placement mapping table
CREATE TABLE IF NOT EXISTS public.ad_system_placements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  system_config_id uuid NOT NULL REFERENCES public.ad_system_config(id) ON DELETE CASCADE,
  placement text NOT NULL,
  is_enabled boolean NOT NULL DEFAULT true,
  priority integer NOT NULL DEFAULT 100,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE(system_config_id, placement)
);

-- Create ad system tier mapping table
CREATE TABLE IF NOT EXISTS public.ad_system_tiers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  system_config_id uuid NOT NULL REFERENCES public.ad_system_config(id) ON DELETE CASCADE,
  tier text NOT NULL,
  is_enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE(system_config_id, tier)
);

-- Create ad system schedule table for more complex scheduling
CREATE TABLE IF NOT EXISTS public.ad_system_schedules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  system_config_id uuid NOT NULL REFERENCES public.ad_system_config(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  
  -- Time-based scheduling
  start_date date NOT NULL,
  end_date date,
  start_time text, -- HH:MM format
  end_time text,   -- HH:MM format
  days_of_week jsonb NOT NULL DEFAULT '["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]'::jsonb,
  
  -- Impression limits for this schedule
  daily_impression_cap integer,
  total_impression_cap integer,
  
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_ad_system_config_type
  ON public.ad_system_config (system_type);

CREATE INDEX IF NOT EXISTS idx_ad_system_placements_config
  ON public.ad_system_placements (system_config_id, is_enabled);

CREATE INDEX IF NOT EXISTS idx_ad_system_tiers_config
  ON public.ad_system_tiers (system_config_id, is_enabled);

CREATE INDEX IF NOT EXISTS idx_ad_system_schedules_config
  ON public.ad_system_schedules (system_config_id, is_active);

-- Create triggers for updated_at
DROP TRIGGER IF EXISTS trigger_ad_system_config_updated_at ON public.ad_system_config;
CREATE TRIGGER trigger_ad_system_config_updated_at
  BEFORE UPDATE ON public.ad_system_config
  FOR EACH ROW
  EXECUTE FUNCTION public.set_row_updated_at();

DROP TRIGGER IF EXISTS trigger_ad_system_placements_updated_at ON public.ad_system_placements;
CREATE TRIGGER trigger_ad_system_placements_updated_at
  BEFORE UPDATE ON public.ad_system_placements
  FOR EACH ROW
  EXECUTE FUNCTION public.set_row_updated_at();

DROP TRIGGER IF EXISTS trigger_ad_system_tiers_updated_at ON public.ad_system_tiers;
CREATE TRIGGER trigger_ad_system_tiers_updated_at
  BEFORE UPDATE ON public.ad_system_tiers
  FOR EACH ROW
  EXECUTE FUNCTION public.set_row_updated_at();

DROP TRIGGER IF EXISTS trigger_ad_system_schedules_updated_at ON public.ad_system_schedules;
CREATE TRIGGER trigger_ad_system_schedules_updated_at
  BEFORE UPDATE ON public.ad_system_schedules
  FOR EACH ROW
  EXECUTE FUNCTION public.set_row_updated_at();

-- Enable RLS
ALTER TABLE public.ad_system_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_system_placements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_system_tiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_system_schedules ENABLE ROW LEVEL SECURITY;

-- Create RLS policies
DROP POLICY IF EXISTS "Admins can manage ad_system_config" ON public.ad_system_config;
CREATE POLICY "Admins can manage ad_system_config"
  ON public.ad_system_config
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

DROP POLICY IF EXISTS "Admins can manage ad_system_placements" ON public.ad_system_placements;
CREATE POLICY "Admins can manage ad_system_placements"
  ON public.ad_system_placements
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

DROP POLICY IF EXISTS "Admins can manage ad_system_tiers" ON public.ad_system_tiers;
CREATE POLICY "Admins can manage ad_system_tiers"
  ON public.ad_system_tiers
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

DROP POLICY IF EXISTS "Admins can manage ad_system_schedules" ON public.ad_system_schedules;
CREATE POLICY "Admins can manage ad_system_schedules"
  ON public.ad_system_schedules
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

-- Initialize default configurations
INSERT INTO public.ad_system_config (system_type, is_enabled, priority)
VALUES
  ('internal', false, 100),
  ('external', false, 101)
ON CONFLICT (system_type) DO NOTHING;

COMMENT ON TABLE public.ad_system_config IS 'Unified configuration for internal and external ad systems with shared controls.';
COMMENT ON TABLE public.ad_system_placements IS 'Per-placement configuration for ad systems.';
COMMENT ON TABLE public.ad_system_tiers IS 'Per-tier configuration for ad systems.';
COMMENT ON TABLE public.ad_system_schedules IS 'Complex scheduling rules for ad systems.';

COMMIT;
