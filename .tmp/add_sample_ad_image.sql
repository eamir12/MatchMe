-- ============================================================================
-- Attach a sample image to the current internal ad campaign ("test").
--
-- STEP 1 (Dashboard): Storage -> sponsored-ad-images bucket -> upload
--   .tmp/sample_ad_banner.png  (generated for you, 1200x400 PNG)
--   Then copy its public URL, e.g.
--   https://<project-ref>.supabase.co/storage/v1/object/public/sponsored-ad-images/sample_ad_banner.png
--
-- STEP 2: paste that URL into the @image_url variable below and run this
--   script in the SQL editor.
--
-- The script updates every creative of the campaign (all placements and
-- platforms) and bumps ads.config_version DIRECTLY — the SQL editor session
-- runs as postgres with no user JWT, so calling admin_touch_ad_config() here
-- would silently no-op on its admin check. The direct bump triggers the same
-- realtime propagation in the MatchMe app as an admin-app save.
-- ============================================================================

BEGIN;

-- STEP 2a: paste the public URL of the uploaded image here:
DO $$
DECLARE
  image_url text := 'PASTE_PUBLIC_URL_HERE';
  v_campaign uuid;
BEGIN
  IF image_url = 'PASTE_PUBLIC_URL_HERE' OR image_url NOT LIKE 'http%' THEN
    RAISE EXCEPTION 'Paste the uploaded image''s public URL into the image_url variable first';
  END IF;

  SELECT id INTO v_campaign
  FROM public.ad_campaigns
  WHERE internal_name = 'test'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_campaign IS NULL THEN
    RAISE EXCEPTION 'Campaign "test" not found';
  END IF;

  UPDATE public.ad_creatives
  SET image_url = image_url
  WHERE campaign_id = v_campaign;

  RAISE NOTICE 'Updated % creatives with the sample image',
    (SELECT count(*) FROM public.ad_creatives WHERE campaign_id = v_campaign AND image_url = image_url);

  -- Realtime epoch bump (same effect as an admin-app save)
  INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
  VALUES (
    'ads.config_version',
    to_jsonb(clock_timestamp()::text),
    'string',
    'ads',
    'Bumped automatically on every ad configuration change; clients use it to invalidate ad caches in realtime.',
    false
  )
  ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value;
END $$;

COMMIT;

-- Verify: all creatives of the campaign should now carry the image
SELECT cr.placement, cr.platform, left(cr.image_url, 60) AS image_url
FROM public.ad_creatives cr
JOIN public.ad_campaigns c ON c.id = cr.campaign_id
WHERE c.internal_name = 'test'
ORDER BY cr.placement, cr.platform;
