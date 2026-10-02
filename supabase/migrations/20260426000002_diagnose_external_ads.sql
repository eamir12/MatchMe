-- Diagnostic script to test external ad serving step by step
-- Run this as an authenticated user to see where the flow breaks

-- 1. Check current user and their tier
SELECT 
  auth.uid() as current_user_id,
  (SELECT subscription_tier FROM public.users WHERE id = auth.uid()) as user_tier;

-- 2. Check if external ads are enabled in config
SELECT 
  config_key,
  config_value,
  config_type
FROM public.app_config
WHERE config_key LIKE 'ads.external.%'
ORDER BY config_key;

-- 3. Check if ad_network is enabled
SELECT 
  id,
  provider,
  display_name,
  is_enabled,
  priority
FROM public.ad_networks
WHERE id = 'fe6c5766-15b9-44f8-b5d7-d97b6bebf4d5';

-- 4. Check available ad_units for a specific placement and platform
SELECT 
  u.id,
  u.placement,
  u.platform,
  u.ad_unit_id,
  u.ad_format,
  u.is_active,
  u.priority,
  n.provider,
  n.is_enabled as network_enabled
FROM public.ad_units u
INNER JOIN public.ad_networks n ON n.id = u.network_id
WHERE u.placement = 'home_inline'
  AND u.platform = 'web'
  AND u.is_active = true
  AND n.is_enabled = true;

-- 5. Test the actual RPC function call (this is what the app calls)
-- This should return an ad unit if everything is configured correctly
SELECT * FROM public.get_external_ad_for_placement('home_inline', 'web');
