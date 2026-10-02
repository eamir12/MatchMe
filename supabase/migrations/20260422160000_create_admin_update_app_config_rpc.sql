-- Create RPC function for admins to update app_config entries with proper type casting
CREATE OR REPLACE FUNCTION admin_update_app_config(
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
END;
$$;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION admin_update_app_config TO authenticated;
