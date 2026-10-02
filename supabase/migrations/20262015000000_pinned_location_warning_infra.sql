-- Migration: Pinned home-base location, step 3 — expiry-warning infrastructure
-- Date: 2026-09-18
-- Depends on: 20262013000000 (pin columns)
-- Purpose: server-side warning pushes before a pin expires, firing even when the
--          app is killed/backgrounded. Mirrors the match_expiry_warnings pattern:
--          thresholds from app_config, per-(user,threshold,expiry) dedup table,
--          enqueue via notification_queue (sent by the existing queue processor).
-- NOTE: notification preference key checked by cron is
--       notification_preferences->'enable_pinned_expiry_notifications'.
--       Missing key defaults to TRUE so warnings work before the client
--       settings UI (step 4) exists.

-- ---------------------------------------------------------------------------
-- 1. Warning thresholds (seconds before expiry). Default: 24h, 1h, 15m.
-- ---------------------------------------------------------------------------
INSERT INTO public.app_config (
  config_key,
  config_value,
  config_type,
  category,
  description,
  is_user_configurable,
  min_value,
  max_value
) VALUES (
  'pinned_location_expiry_warning_seconds',
  '[86400, 3600, 900]',
  'array',
  'notification',
  'When to warn about pinned-location expiry (seconds before expiry)',
  false,
  null,
  null
)
ON CONFLICT (config_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Dedup table: one row per (user, threshold, expiry).
--    Expiry is part of the key so extending a pin re-arms all thresholds,
--    same extension-aware semantics as match_expiry_warnings.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pinned_location_warnings (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  threshold_seconds integer NOT NULL CHECK (threshold_seconds > 0),
  expiry_at timestamptz NOT NULL,
  warned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, threshold_seconds, expiry_at)
);

CREATE INDEX IF NOT EXISTS idx_pinned_location_warnings_user_id ON public.pinned_location_warnings (user_id);
CREATE INDEX IF NOT EXISTS idx_pinned_location_warnings_warned_at ON public.pinned_location_warnings (warned_at);

ALTER TABLE public.pinned_location_warnings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role can manage pinned warnings" ON public.pinned_location_warnings;
CREATE POLICY "Service role can manage pinned warnings"
  ON public.pinned_location_warnings FOR ALL
  TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Users can view own pinned warnings" ON public.pinned_location_warnings;
CREATE POLICY "Users can view own pinned warnings"
  ON public.pinned_location_warnings FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

GRANT ALL ON public.pinned_location_warnings TO service_role;
GRANT SELECT ON public.pinned_location_warnings TO authenticated;
