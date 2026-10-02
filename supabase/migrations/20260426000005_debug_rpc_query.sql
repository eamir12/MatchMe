-- Debug the exact query conditions used by get_external_ad_for_placement RPC
-- This mimics exactly what the RPC does at the end

-- =====================================================
-- The RPC's final query (exact conditions)
-- =====================================================
SELECT 
  'RPC Final Query Conditions' as debug_step,
  u.id,
  u.network_id,
  u.placement,
  u.platform,
  u.ad_unit_id,
  u.ad_format,
  u.is_active as unit_is_active,
  n.is_enabled as network_is_enabled,
  n.priority as network_priority,
  u.priority as unit_priority,
  -- Check each condition
  CASE WHEN n.is_enabled = true THEN '✓' ELSE '✗ Network disabled' END as check_network,
  CASE WHEN u.is_active = true THEN '✓' ELSE '✗ Unit inactive' END as check_unit,
  CASE WHEN u.placement = 'home_inline' THEN '✓' ELSE '✗ Wrong placement' END as check_placement,
  CASE WHEN u.platform IN ('web', 'web') THEN '✓' ELSE '✗ Wrong platform' END as check_platform
FROM public.ad_units u
INNER JOIN public.ad_networks n ON n.id = u.network_id
WHERE n.is_enabled = true
  AND u.is_active = true
  AND u.placement = 'home_inline'
  AND u.platform IN ('web', 'web')
ORDER BY n.priority ASC, u.priority ASC
LIMIT 1;


-- =====================================================
-- Check ALL ad units for home_inline + web (not just active ones)
-- =====================================================
SELECT 
  u.id,
  u.placement,
  u.platform,
  u.ad_unit_id,
  u.ad_format,
  u.is_active,
  n.is_enabled,
  u.network_id,
  n.id as network_id_check,
  CASE 
    WHEN u.is_active AND n.is_enabled THEN '✓ Would be returned by RPC'
    ELSE '✗ Would NOT be returned'
  END as rpc_would_return
FROM public.ad_units u
LEFT JOIN public.ad_networks n ON n.id = u.network_id
WHERE u.placement = 'home_inline'
  AND u.platform = 'web';


-- =====================================================
-- Check if there's a network_id mismatch
-- =====================================================
SELECT 
  'Network ID Check' as check_type,
  (SELECT id FROM public.ad_networks WHERE id = 'fe6c5766-15b9-44f8-b5d7-d97b6bebf4d5') as network_exists,
  (SELECT is_enabled FROM public.ad_networks WHERE id = 'fe6c5766-15b9-44f8-b5d7-d97b6bebf4d5') as network_enabled,
  (SELECT count(*) FROM public.ad_units WHERE network_id = 'fe6c5766-15b9-44f8-b5d7-d97b6bebf4d5' AND placement = 'home_inline' AND platform = 'web') as matching_units_count;


-- =====================================================
-- Test with hardcoded user to bypass auth check
-- =====================================================
-- Create a test function that doesn't require auth
CREATE OR REPLACE FUNCTION public.test_get_external_ad()
RETURNS TABLE (
  id uuid,
  network_id uuid,
  placement text,
  platform text,
  ad_format text,
  ad_unit_id text,
  is_active boolean,
  priority int
) 
LANGUAGE sql
SECURITY DEFINER
AS $$
  -- Same logic but without auth.uid() check
  SELECT
    u.id,
    u.network_id,
    u.placement,
    u.platform,
    u.ad_format,
    u.ad_unit_id,
    u.is_active,
    u.priority
  FROM public.ad_networks n
  INNER JOIN public.ad_units u ON u.network_id = n.id
  WHERE n.is_enabled = true
    AND u.is_active = true
    AND u.placement = 'home_inline'
    AND u.platform = 'web'
  ORDER BY n.priority ASC, u.priority ASC
  LIMIT 1;
$$;

-- Run the test
SELECT * FROM public.test_get_external_ad();
