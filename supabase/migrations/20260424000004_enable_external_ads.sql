-- Enable external ads system
-- The system was initialized with ads.external.enabled = false
-- This migration enables it so ads can be displayed

BEGIN;

UPDATE public.app_config 
SET config_value = 'true'
WHERE config_key = 'ads.external.enabled';

COMMIT;
