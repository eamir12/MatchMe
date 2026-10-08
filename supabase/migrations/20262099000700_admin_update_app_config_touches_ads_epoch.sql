-- ============================================================================
-- Close the last realtime gap for ad settings: the admin app's generic
-- "Manage app_config" screen writes ANY config key through the
-- admin_update_app_config RPC without calling admin_touch_ad_config(), so an
-- ads.* key edited there updated the value but never bumped
-- ads.config_version — the MatchMe app kept serving the old behaviour until
-- its next periodic refetch.
--
-- Fix: the RPC itself bumps the epoch whenever the written key belongs to the
-- ads category. Server-side guarantee — covers this screen and ANY other
-- caller of the RPC (dashboards that touch explicitly remain unaffected; the
-- touch is idempotent).
--
-- Idempotent: CREATE OR REPLACE with identical behaviour on re-run.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_update_app_config(
  p_config_key TEXT,
  p_config_value JSONB,
  p_config_type TEXT,
  p_category TEXT,
  p_description TEXT,
  p_is_user_configurable BOOLEAN,
  p_min_value NUMERIC DEFAULT NULL,
  p_max_value NUMERIC DEFAULT NULL,
  p_allowed_values JSONB DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Check if user is admin
  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid() AND is_admin = true
  ) THEN
    RAISE EXCEPTION 'Permission denied: user is not an admin';
  END IF;

  INSERT INTO app_config (
    config_key,
    config_value,
    config_type,
    category,
    description,
    is_user_configurable,
    min_value,
    max_value,
    allowed_values
  ) VALUES (
    p_config_key,
    p_config_value,
    p_config_type,
    p_category,
    p_description,
    p_is_user_configurable,
    p_min_value,
    p_max_value,
    p_allowed_values
  )
  ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value,
    config_type = EXCLUDED.config_type,
    category = EXCLUDED.category,
    description = EXCLUDED.description,
    is_user_configurable = EXCLUDED.is_user_configurable,
    min_value = EXCLUDED.min_value,
    max_value = EXCLUDED.max_value,
    allowed_values = EXCLUDED.allowed_values,
    updated_at = NOW();

  -- Realtime: any ad-setting change must reach the MatchMe app immediately.
  -- admin_touch_ad_config bumps ads.config_version; it re-checks admin but
  -- this caller already passed the check above.
  IF p_config_key LIKE 'ads.%' THEN
    PERFORM public.admin_touch_ad_config();
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_update_app_config(
  text, jsonb, text, text, text, boolean, numeric, numeric, jsonb
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_app_config(
  text, jsonb, text, text, text, boolean, numeric, numeric, jsonb
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_app_config(
  text, jsonb, text, text, text, boolean, numeric, numeric, jsonb
) TO service_role;

COMMIT;
