-- ============================================================================
-- Realtime ad-config epoch.
--
-- The MatchMe app cannot subscribe to ad_campaigns/ad_creatives/ad_units
-- changes directly (RLS correctly hides them from non-admins, and realtime
-- postgres_changes applies RLS per subscriber). It CAN subscribe to
-- app_config, which is in the supabase_realtime publication and readable by
-- authenticated users.
--
-- So: every admin write to the ad systems calls admin_touch_ad_config(),
-- which bumps ads.config_version to the current timestamp. The client watches
-- that key over the existing app_config realtime stream and hard-invalidates
-- all ad caches (bypassing the debounce/reuse windows) the moment it changes.
--
-- Seed the key so clients see a stable initial value.
-- ============================================================================

BEGIN;

INSERT INTO public.app_config (
  config_key,
  config_value,
  config_type,
  category,
  description,
  is_user_configurable
) VALUES (
  'ads.config_version',
  to_jsonb(clock_timestamp()::text),
  'string',
  'ads',
  'Bumped automatically by admin_touch_ad_config() on every ad configuration change; clients use it to invalidate ad caches in realtime.',
  false
)
ON CONFLICT (config_key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.admin_touch_ad_config()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Admin-only: non-admin callers are silently ignored (no info leak).
  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid() AND is_admin = true
  ) THEN
    RETURN;
  END IF;

  INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
  VALUES (
    'ads.config_version',
    to_jsonb(clock_timestamp()::text),
    'string',
    'ads',
    'Bumped automatically by admin_touch_ad_config() on every ad configuration change; clients use it to invalidate ad caches in realtime.',
    false
  )
  ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_touch_ad_config() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_touch_ad_config() TO authenticated;

COMMIT;
