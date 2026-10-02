-- Remove deprecated ads.internal.free_tier_only config
-- This is replaced by ads.internal.allowed_tiers

BEGIN;

-- Delete the deprecated config if it exists
DELETE FROM public.app_config
WHERE config_key = 'ads.internal.free_tier_only';

-- Ensure allowed_tiers is set with proper default if not exists
INSERT INTO public.app_config (config_key, config_value, config_type, description, category, is_user_configurable)
SELECT 
  'ads.internal.allowed_tiers',
  '["free", "plus", "gold", "platinum"]',
  'array',
  'Master list of subscription tiers that can receive internal ads.',
  'ads',
  false
WHERE NOT EXISTS (
  SELECT 1 FROM public.app_config WHERE config_key = 'ads.internal.allowed_tiers'
);

COMMIT;
