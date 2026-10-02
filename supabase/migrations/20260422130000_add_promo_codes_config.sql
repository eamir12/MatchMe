-- Add promo_codes_enabled config to app_config table
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable) VALUES
('promo_codes_enabled', 'true', 'boolean', 'promo', 'Controls whether users can redeem promo codes in the app', false)
ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value,
    config_type = EXCLUDED.config_type,
    category = EXCLUDED.category,
    description = EXCLUDED.description,
    is_user_configurable = EXCLUDED.is_user_configurable;

-- Create RPC function for admins to update promo_codes_enabled config
CREATE OR REPLACE FUNCTION admin_update_promo_codes_config(p_enabled BOOLEAN)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE app_config
    SET config_value = p_enabled::text::jsonb,
        updated_at = NOW()
    WHERE config_key = 'promo_codes_enabled';
END;
$$;

-- Grant execute permission to authenticated users (RLS will restrict to admins)
GRANT EXECUTE ON FUNCTION admin_update_promo_codes_config TO authenticated;
