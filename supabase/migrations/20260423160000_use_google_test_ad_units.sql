-- Use Google's official test ad unit IDs for development/testing
-- These always return test ads and don't require app approval

BEGIN;

-- Update the AdMob network with Google's test App ID
UPDATE public.ad_networks 
SET config = '{"app_id": "ca-app-pub-3940256099942544~3347511713", "test_device_ids": []}'
WHERE provider = 'admob';

-- Update all ad units to use Google's test ad unit IDs
-- Banner test IDs
UPDATE public.ad_units 
SET ad_unit_id = 'ca-app-pub-3940256099942544/6300978111'
WHERE placement IN ('home_inline', 'matches_inline', 'chats_inline', 'events_inline')
  AND platform IN ('android', 'web')
  AND ad_format = 'banner'
  AND network_id = (SELECT id FROM public.ad_networks WHERE provider = 'admob');

UPDATE public.ad_units 
SET ad_unit_id = 'ca-app-pub-3940256099942544/2934735716'
WHERE placement IN ('home_inline', 'matches_inline', 'chats_inline', 'events_inline')
  AND platform = 'ios'
  AND ad_format = 'banner'
  AND network_id = (SELECT id FROM public.ad_networks WHERE provider = 'admob');

-- Native test IDs
UPDATE public.ad_units 
SET ad_unit_id = 'ca-app-pub-3940256099942544/2247696110'
WHERE placement IN ('home_inline', 'matches_inline')
  AND platform = 'android'
  AND ad_format = 'native'
  AND network_id = (SELECT id FROM public.ad_networks WHERE provider = 'admob');

UPDATE public.ad_units 
SET ad_unit_id = 'ca-app-pub-3940256099942544/3986624511'
WHERE placement IN ('home_inline', 'matches_inline')
  AND platform = 'ios'
  AND ad_format = 'native'
  AND network_id = (SELECT id FROM public.ad_networks WHERE provider = 'admob');

COMMIT;
