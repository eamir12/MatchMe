-- Diagnose why platinum user doesn't see the ad
-- Run these queries to identify the issue

-- 1. Check the campaign details
SELECT 
  c.id,
  c.internal_name,
  c.target_tiers,
  c.is_active,
  c.moderation_status,
  c.starts_at,
  c.ends_at,
  c.family_safe
FROM public.ad_campaigns c
WHERE c.id = '55812113-01b0-40ee-b779-4b5e4943a6db';

-- 2. Check creatives for this campaign
SELECT 
  cr.id,
  cr.campaign_id,
  cr.placement,
  cr.platform,
  cr.is_active,
  cr.headline_key,
  cr.image_url
FROM public.ad_creatives cr
WHERE cr.campaign_id = '55812113-01b0-40ee-b779-4b5e4943a6db';

-- 3. Check translations for the creative keys
SELECT 
  t.locale,
  t.key,
  t.value
FROM public.translations t
WHERE t.key LIKE '%55812113%'
   OR t.key IN (
     SELECT headline_key FROM public.ad_creatives 
     WHERE campaign_id = '55812113-01b0-40ee-b779-4b5e4943a6db'
   );

-- 4. Test the function directly with a free user context
-- (Replace with actual free user ID)
-- SET LOCAL ROLE authenticated;
-- SET request.jwt.claim.sub = 'free-user-id-here';
-- SELECT * FROM public.get_sponsored_ad_for_placement('home_inline', 'en', 'web');

-- 5. Test with platinum user context
-- (Replace with actual platinum user ID)
-- SET LOCAL ROLE authenticated;
-- SET request.jwt.claim.sub = 'platinum-user-id-here';
-- SELECT * FROM public.get_sponsored_ad_for_placement('home_inline', 'en', 'web');

-- 6. Check if the tier is correctly formatted in the database
-- (The tier should be lowercase 'platinum', not 'Platinum')
SELECT 
  subscription_tier,
  LOWER(TRIM(subscription_tier)) as normalized_tier
FROM public.users
WHERE subscription_tier ILIKE '%platinum%';

-- 7. Debug: Check what the function sees step by step
WITH test_data AS (
  SELECT 
    '55812113-01b0-40ee-b779-4b5e4943a6db'::uuid as campaign_id,
    'platinum'::text as test_tier
)
SELECT 
  c.id,
  c.target_tiers,
  c.target_tiers IS NULL as is_null,
  array_length(c.target_tiers, 1) as array_length,
  'platinum' = ANY(c.target_tiers) as tier_matches,
  CASE 
    WHEN c.target_tiers IS NULL THEN 'NULL - would match'
    WHEN array_length(c.target_tiers, 1) IS NULL THEN 'NULL length - would match'
    WHEN array_length(c.target_tiers, 1) = 0 THEN 'Empty - would match'
    WHEN 'platinum' = ANY(c.target_tiers) THEN 'Matches platinum'
    ELSE 'Does NOT match platinum'
  END as filter_result
FROM public.ad_campaigns c
WHERE c.id = '55812113-01b0-40ee-b779-4b5e4943a6db';
