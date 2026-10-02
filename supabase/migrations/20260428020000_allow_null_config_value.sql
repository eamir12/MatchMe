-- Allow NULL values in config_value for rate limit configs (represents "no limit")
-- This is needed for ads.external.max_impressions_per_user_per_day and ads.external.max_impressions_per_user_per_hour

BEGIN;

-- Alter the column to allow NULL values
ALTER TABLE public.app_config 
ALTER COLUMN config_value DROP NOT NULL;

COMMIT;
