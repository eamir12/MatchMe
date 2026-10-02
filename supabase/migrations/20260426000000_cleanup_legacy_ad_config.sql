-- Cleanup script to delete legacy/unused ad config keys
-- Run this in your Supabase SQL Editor

BEGIN;

-- Delete legacy keys (IDs 401-411, 417) that are no longer used
-- The app now uses ads.internal.* and ads.external.* prefixed keys
DELETE FROM public.app_config 
WHERE config_key IN (
    -- Legacy keys (replaced by ads.internal.*)
    'ads.enabled',
    'ads.free_tier_only', 
    'ads.family_safe_only',
    'ads.sponsored_cards_enabled',
    'ads.mobile.native_enabled',
    'ads.mobile.provider',
    'ads.allowed_placements',
    'ads.max_impressions_per_session',
    'ads.min_minutes_between_impressions',
    'ads.first_impression_delay_seconds',
    'ads.report_enabled',
    
    -- Legacy key (replaced by ads.external.enabled with dot)
    'ads.external_enabled',
    
    -- Unused external ad keys (we use ad_networks table instead)
    'ads.external.admob_enabled',
    'ads.external.mediation_enabled',
    'ads.external.personalized_ads_default',
    'ads.external.show_consent_form',
    'ads.external.min_user_age_for_personalization',
    'ads.external.facebook_enabled',
    'ads.external.applovin_enabled',
    'ads.external.unity_enabled'
);

-- After running this, the only remaining keys should be:
-- INTERNAL ADS (ads.internal.*):
--   - ads.internal.enabled
--   - ads.internal.free_tier_only
--   - ads.internal.sponsored_cards_enabled
--   - ads.internal.allowed_placements
--   - ads.internal.allowed_tiers
--   - ads.internal.allowed_platforms
--   - ads.internal.max_impressions_per_session
--   - ads.internal.min_minutes_between_impressions
--   - ads.internal.first_impression_delay_seconds
--   - ads.internal.report_enabled
--   - ads.internal.mobile.native_enabled
--   - ads.internal.mobile.provider
--   - ads.internal.family_safe_only
--
-- EXTERNAL ADS (ads.external.*):
--   - ads.external.enabled
--   - ads.external.allowed_placements
--   - ads.external.allowed_tiers
--   - ads.external.allowed_platforms
--   - ads.external.max_impressions_per_user_per_day
--   - ads.external.max_impressions_per_user_per_hour

COMMIT;
