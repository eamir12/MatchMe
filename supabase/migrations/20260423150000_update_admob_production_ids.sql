-- Update AdMob network with production App ID and ad units with production unit IDs

BEGIN;

-- Update the AdMob network with production App ID
UPDATE public.ad_networks 
SET config = '{"app_id": "ca-app-pub-1071857314988867~7605526456", "test_device_ids": []}'
WHERE provider = 'admob';

-- Update all ad units to use the production ad unit ID
UPDATE public.ad_units 
SET ad_unit_id = 'ca-app-pub-1071857314988867/7828887730'
WHERE network_id = (SELECT id FROM public.ad_networks WHERE provider = 'admob');

COMMIT;
