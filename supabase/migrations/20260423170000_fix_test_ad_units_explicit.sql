-- Explicitly set Google test ad unit IDs for all placements
-- This ensures test ads will load without app approval

BEGIN;

-- Get the AdMob network ID
WITH admob_network AS (
  SELECT id FROM public.ad_networks WHERE provider = 'admob' LIMIT 1
)

-- Delete existing ad units to start fresh
DELETE FROM public.ad_units 
WHERE network_id = (SELECT id FROM admob_network);

-- Re-insert with Google's test ad unit IDs
WITH admob_network AS (
  SELECT id FROM public.ad_networks WHERE provider = 'admob' LIMIT 1
)
INSERT INTO public.ad_units (network_id, placement, platform, ad_unit_id, ad_format, is_active, priority)
VALUES
  -- Home inline - Banner
  ((SELECT id FROM admob_network), 'home_inline', 'android', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  ((SELECT id FROM admob_network), 'home_inline', 'ios', 'ca-app-pub-3940256099942544/2934735716', 'banner', true, 100),
  ((SELECT id FROM admob_network), 'home_inline', 'web', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  
  -- Matches inline - Banner
  ((SELECT id FROM admob_network), 'matches_inline', 'android', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  ((SELECT id FROM admob_network), 'matches_inline', 'ios', 'ca-app-pub-3940256099942544/2934735716', 'banner', true, 100),
  ((SELECT id FROM admob_network), 'matches_inline', 'web', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  
  -- Chats inline - Banner
  ((SELECT id FROM admob_network), 'chats_inline', 'android', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  ((SELECT id FROM admob_network), 'chats_inline', 'ios', 'ca-app-pub-3940256099942544/2934735716', 'banner', true, 100),
  ((SELECT id FROM admob_network), 'chats_inline', 'web', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  
  -- Events inline - Banner
  ((SELECT id FROM admob_network), 'events_inline', 'android', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  ((SELECT id FROM admob_network), 'events_inline', 'ios', 'ca-app-pub-3940256099942544/2934735716', 'banner', true, 100),
  ((SELECT id FROM admob_network), 'events_inline', 'web', 'ca-app-pub-3940256099942544/6300978111', 'banner', true, 100),
  
  -- Home inline - Native
  ((SELECT id FROM admob_network), 'home_inline', 'android', 'ca-app-pub-3940256099942544/2247696110', 'native', true, 100),
  ((SELECT id FROM admob_network), 'home_inline', 'ios', 'ca-app-pub-3940256099942544/3986624511', 'native', true, 100),
  
  -- Matches inline - Native
  ((SELECT id FROM admob_network), 'matches_inline', 'android', 'ca-app-pub-3940256099942544/2247696110', 'native', true, 100),
  ((SELECT id FROM admob_network), 'matches_inline', 'ios', 'ca-app-pub-3940256099942544/3986624511', 'native', true, 100);

COMMIT;
