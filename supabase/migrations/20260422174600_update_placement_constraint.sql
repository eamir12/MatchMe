-- Update the placement check constraint to include new placements
-- Drop the old constraint and create a new one with all valid placements

ALTER TABLE ad_creatives DROP CONSTRAINT IF EXISTS ad_creatives_placement_check;

ALTER TABLE ad_creatives ADD CONSTRAINT ad_creatives_placement_check
  CHECK (placement IN ('home_inline', 'matches_inline', 'chats_inline', 'events_inline'));

-- Update the allowed placements in app_config
UPDATE app_config
SET config_value = '["home_inline", "matches_inline", "chats_inline", "events_inline"]'::jsonb,
    updated_at = NOW()
WHERE config_key = 'ads.allowed_placements';

-- Drop the HTTPS destination URL requirement constraint from ad_campaigns
-- URL is now optional - if provided it must be HTTPS, but empty is allowed
ALTER TABLE ad_campaigns DROP CONSTRAINT IF EXISTS ad_campaigns_https_destination_url;
