-- Fix admin_update_promo_codes_config to properly cast boolean to jsonb
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
