-- Add the actual device test ID from the logs
-- Device ID: D7A22098E7B8BDCE766C9DDB1F5FE61B6

BEGIN;

-- Update the AdMob network configuration to include the actual device test ID
UPDATE public.ad_networks 
SET config = '{"app_id": "ca-app-pub-3940256099942544~3347511713", "test_device_ids": ["D7A22098E7B8BDCE766C9DDB1F5FE61B6", "33BE2250B43518CCDA7DE426D04EE232"]}'
WHERE provider = 'admob';

COMMIT;
