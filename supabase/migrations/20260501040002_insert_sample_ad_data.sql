-- ============================================
-- INSERT SAMPLE AD DATA FOR TESTING
-- Run this to create a test campaign with translations
-- ============================================

BEGIN;

-- Step 1: Insert sample translations for the ad
-- These are the translation keys the ad system will look for
INSERT INTO public.translations (locale, key, value) VALUES
  -- English
  ('en', 'ad.sample.headline', 'Discover Premium Features!'),
  ('en', 'ad.sample.body', 'Upgrade your experience with exclusive tools and benefits.'),
  ('en', 'ad.sample.cta', 'Learn More'),
  ('en', 'ad.sample.sponsor', 'MatchMe Premium'),
  
  -- Spanish
  ('es', 'ad.sample.headline', '¡Descubre Funciones Premium!'),
  ('es', 'ad.sample.body', 'Mejora tu experiencia con herramientas y beneficios exclusivos.'),
  ('es', 'ad.sample.cta', 'Más Información'),
  ('es', 'ad.sample.sponsor', 'MatchMe Premium'),
  
  -- Hebrew
  ('he', 'ad.sample.headline', 'גלו תכונות פרימיום!'),
  ('he', 'ad.sample.body', 'שדרגו את החוויה שלכם עם כלים והטבות בלעדיים.'),
  ('he', 'ad.sample.cta', 'למידע נוסף'),
  ('he', 'ad.sample.sponsor', 'MatchMe פרימיום')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Step 2: Create a sample campaign (only if none exist)
DO $$
DECLARE
  v_campaign_id uuid;
  v_creative_id uuid;
BEGIN
  -- Check if we already have campaigns
  IF NOT EXISTS (SELECT 1 FROM public.ad_campaigns LIMIT 1) THEN
    -- Insert sample campaign
    INSERT INTO public.ad_campaigns (
      internal_name,
      advertiser_name,
      destination_url,
      moderation_status,
      family_safe,
      is_active,
      starts_at,
      ends_at,
      sort_priority
    ) VALUES (
      'Sample Test Campaign',
      'MatchMe Team',
      'https://matchme.app/premium',
      'approved',
      true,
      true,
      NOW() - INTERVAL '1 day',  -- Started yesterday
      NOW() + INTERVAL '30 days', -- Ends in 30 days
      100
    )
    RETURNING id INTO v_campaign_id;

    -- Insert creative for home_inline placement
    INSERT INTO public.ad_creatives (
      campaign_id,
      placement,
      platform,
      headline_key,
      body_key,
      cta_key,
      sponsor_name_key,
      image_url,
      is_active,
      sort_priority
    ) VALUES (
      v_campaign_id,
      'home_inline',
      'all',
      'ad.sample.headline',
      'ad.sample.body',
      'ad.sample.cta',
      'ad.sample.sponsor',
      'https://placehold.co/600x400/4A90E2/FFFFFF/png?text=MatchMe+Premium',
      true,
      100
    );

    -- Insert creative for matches_inline placement
    INSERT INTO public.ad_creatives (
      campaign_id,
      placement,
      platform,
      headline_key,
      body_key,
      cta_key,
      sponsor_name_key,
      image_url,
      is_active,
      sort_priority
    ) VALUES (
      v_campaign_id,
      'matches_inline',
      'all',
      'ad.sample.headline',
      'ad.sample.body',
      'ad.sample.cta',
      'ad.sample.sponsor',
      'https://placehold.co/600x400/4A90E2/FFFFFF/png?text=MatchMe+Premium',
      true,
      100
    );

    -- Insert creative for profile_inline placement
    INSERT INTO public.ad_creatives (
      campaign_id,
      placement,
      platform,
      headline_key,
      body_key,
      cta_key,
      sponsor_name_key,
      image_url,
      is_active,
      sort_priority
    ) VALUES (
      v_campaign_id,
      'profile_inline',
      'all',
      'ad.sample.headline',
      'ad.sample.body',
      'ad.sample.cta',
      'ad.sample.sponsor',
      'https://placehold.co/600x400/4A90E2/FFFFFF/png?text=MatchMe+Premium',
      true,
      100
    );

    RAISE NOTICE 'Created sample campaign with ID: %', v_campaign_id;
  ELSE
    RAISE NOTICE 'Campaigns already exist, skipping sample data creation';
  END IF;
END $$;

COMMIT;

-- ============================================
-- VERIFICATION QUERIES (Run these after)
-- ============================================

-- Check the sample data was created
SELECT 
  'Sample Data Verification' as check_type,
  c.id as campaign_id,
  c.internal_name,
  c.is_active,
  c.moderation_status,
  cr.placement,
  cr.headline_key,
  cr.is_active as creative_active
FROM public.ad_campaigns c
JOIN public.ad_creatives cr ON cr.campaign_id = c.id
WHERE c.internal_name = 'Sample Test Campaign'
   OR c.internal_name LIKE '%Sample%';

-- Check translations exist
SELECT locale, key, value 
FROM public.translations 
WHERE key LIKE 'ad.sample.%'
ORDER BY key, locale;

-- Test if the function would return an ad now (run this as authenticated user in your app)
-- SELECT * FROM public.get_sponsored_ad_for_placement('home_inline', 'en', 'android');
