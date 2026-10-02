--- Insert missing ad_creatives for matches_inline and chats_inline
--- to match the admin "Allowed Placements" configuration.
--- Uses the same demo campaign and translation keys as existing creatives.

BEGIN;

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
)
SELECT
  '55812113-01b0-40ee-b779-4b5e4943a6db'::uuid,
  p.placement,
  p.platform,
  'ads_test_1777449306261_headline',
  'ads_test_1777449306261_body',
  'ads_test_1777449306261_cta',
  'ads_test_1777449306262_sponsor',
  null,
  true,
  100
FROM (VALUES
  ('matches_inline', 'android'),
  ('matches_inline', 'ios'),
  ('matches_inline', 'web'),
  ('chats_inline',   'android'),
  ('chats_inline',   'ios'),
  ('chats_inline',   'web')
) AS p(placement, platform)
WHERE NOT EXISTS (
  SELECT 1 FROM public.ad_creatives c
  WHERE c.campaign_id = '55812113-01b0-40ee-b779-4b5e4943a6db'::uuid
    AND c.placement = p.placement
    AND c.platform = p.platform
);

COMMIT;
