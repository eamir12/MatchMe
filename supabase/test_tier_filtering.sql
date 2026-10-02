-- Test script for tier filtering in get_sponsored_ad_for_placement
-- This script creates test campaigns with different target_tiers and tests the function with different user contexts

-- Note: This script assumes you have test users with different subscription_tiers
-- Replace 'free_user_id', 'premium_user_id' with actual user IDs

-- Create test campaigns
INSERT INTO public.ad_campaigns (id, advertiser_name, destination_url, is_active, family_safe, moderation_status, starts_at, target_tiers)
VALUES
  ('test_campaign_free_only', 'Free Sponsor', 'https://free.com', true, true, 'approved', NOW(), '["free"]'::jsonb),
  ('test_campaign_premium_only', 'Premium Sponsor', 'https://premium.com', true, true, 'approved', NOW(), '["premium"]'::jsonb),
  ('test_campaign_all_tiers', 'All Sponsor', 'https://all.com', true, true, 'approved', NOW(), NULL),
  ('test_campaign_no_tiers', 'No Tiers Sponsor', 'https://no.com', true, true, 'approved', NOW(), '[]'::jsonb);

-- Create test creatives
INSERT INTO public.ad_creatives (id, campaign_id, placement, platform, image_url, headline_key, body_key, cta_key, sponsor_name_key, is_active)
VALUES
  ('test_creative_free', 'test_campaign_free_only', 'home_inline', 'all', 'https://free.com/image.jpg', 'free_headline', 'free_body', 'free_cta', 'free_sponsor', true),
  ('test_creative_premium', 'test_campaign_premium_only', 'home_inline', 'all', 'https://premium.com/image.jpg', 'premium_headline', 'premium_body', 'premium_cta', 'premium_sponsor', true),
  ('test_creative_all', 'test_campaign_all_tiers', 'home_inline', 'all', 'https://all.com/image.jpg', 'all_headline', 'all_body', 'all_cta', 'all_sponsor', true),
  ('test_creative_no', 'test_campaign_no_tiers', 'home_inline', 'all', 'https://no.com/image.jpg', 'no_headline', 'no_body', 'no_cta', 'no_sponsor', true);

-- Insert translations for the keys
INSERT INTO public.translations (locale, key, value)
VALUES
  ('en', 'free_headline', 'Free Tier Ad'),
  ('en', 'free_body', 'This ad is for free users'),
  ('en', 'free_cta', 'Free Action'),
  ('en', 'free_sponsor', 'Free Sponsor'),
  ('en', 'premium_headline', 'Premium Tier Ad'),
  ('en', 'premium_body', 'This ad is for premium users'),
  ('en', 'premium_cta', 'Premium Action'),
  ('en', 'premium_sponsor', 'Premium Sponsor'),
  ('en', 'all_headline', 'All Tiers Ad'),
  ('en', 'all_body', 'This ad is for all users'),
  ('en', 'all_cta', 'All Action'),
  ('en', 'all_sponsor', 'All Sponsor'),
  ('en', 'no_headline', 'No Tiers Ad'),
  ('en', 'no_body', 'This ad has no target tiers'),
  ('en', 'no_cta', 'No Action'),
  ('en', 'no_sponsor', 'No Sponsor');

-- Test queries (run these with different auth.uid() contexts)

-- Test with free user (should see free_only, all_tiers, no_tiers)
-- SELECT * FROM public.get_sponsored_ad_for_placement('home_inline', 'en', 'web');

-- Test with premium user (should see premium_only, all_tiers, no_tiers)
-- SELECT * FROM public.get_sponsored_ad_for_placement('home_inline', 'en', 'web');

-- To test with different users, you need to set the auth context
-- For example, in Supabase SQL editor or via RPC with auth

-- Cleanup (run after testing)
-- DELETE FROM public.ad_creatives WHERE id LIKE 'test_%';
-- DELETE FROM public.ad_campaigns WHERE id LIKE 'test_%';
-- DELETE FROM public.translations WHERE key LIKE '%headline' OR key LIKE '%body' OR key LIKE '%cta' OR key LIKE '%sponsor';