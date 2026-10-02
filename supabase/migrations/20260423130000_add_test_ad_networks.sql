-- Add test ad networks and units for development/testing
-- Uses Google AdMob test ad unit IDs
-- Also enables external ads system in configuration

BEGIN;

-- Enable external ads system
UPDATE public.app_config 
SET config_value = 'true'
WHERE config_key = 'ads.external.enabled';

-- Enable AdMob in configuration
UPDATE public.app_config 
SET config_value = 'true'
WHERE config_key = 'ads.external.admob_enabled';

-- Enable mediation
UPDATE public.app_config 
SET config_value = 'true'
WHERE config_key = 'ads.external.mediation_enabled';

-- Insert test AdMob network
INSERT INTO public.ad_networks (provider, display_name, is_enabled, priority, config)
VALUES (
  'admob',
  'Google AdMob (Test)',
  true,
  100,
  '{"app_id": "ca-app-pub-3940256099942544~3347511713", "test_device_ids": ["33BE2250B43518CCDA7DE426D04EE232"]}'
)
ON CONFLICT (provider) DO UPDATE SET
  is_enabled = true,
  config = '{"app_id": "ca-app-pub-3940256099942544~3347511713", "test_device_ids": ["33BE2250B43518CCDA7DE426D04EE232"]}';

-- Get the network ID and insert ad units
WITH network AS (
  SELECT id FROM public.ad_networks WHERE provider = 'admob' LIMIT 1
)
INSERT INTO public.ad_units (network_id, placement, platform, ad_unit_id, ad_format, is_active, priority)
VALUES
  -- Home inline placements
  ((SELECT id FROM network), 'home_inline', 'android', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  ((SELECT id FROM network), 'home_inline', 'ios', 'ca-app-pub-3940256099942544/2934735716', 'banner', true, 100),
  ((SELECT id FROM network), 'home_inline', 'web', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  
  -- Matches inline placements
  ((SELECT id FROM network), 'matches_inline', 'android', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  ((SELECT id FROM network), 'matches_inline', 'ios', 'ca-app-pub-3940256099942544/2934735716', 'banner', true, 100),
  ((SELECT id FROM network), 'matches_inline', 'web', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  
  -- Chats inline placements
  ((SELECT id FROM network), 'chats_inline', 'android', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  ((SELECT id FROM network), 'chats_inline', 'ios', 'ca-app-pub-3940256099942544/2934735716', 'banner', true, 100),
  ((SELECT id FROM network), 'chats_inline', 'web', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  
  -- Events inline placements
  ((SELECT id FROM network), 'events_inline', 'android', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  ((SELECT id FROM network), 'events_inline', 'ios', 'ca-app-pub-3940256099942544/2934735716', 'banner', true, 100),
  ((SELECT id FROM network), 'events_inline', 'web', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  
  -- Native ads (mobile only)
  ((SELECT id FROM network), 'home_inline', 'android', 'ca-app-pub-3940256099942544/2247696110', 'native', true, 100),
  ((SELECT id FROM network), 'home_inline', 'ios', 'ca-app-pub-3940256099942544/3986624511', 'native', true, 100),
  ((SELECT id FROM network), 'matches_inline', 'android', 'ca-app-pub-3940256099942544/2247696110', 'native', true, 100),
  ((SELECT id FROM network), 'matches_inline', 'ios', 'ca-app-pub-3940256099942544/3986624511', 'native', true, 100)
ON CONFLICT DO NOTHING;

COMMIT;
