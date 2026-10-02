-- Add translations for Profile ad placement and mutual exclusivity messages
-- These are used in both internal and external ad dashboards

BEGIN;

-- Internal ads dashboard - Profile placement label
INSERT INTO public.translations (key, locale, value, created_at, updated_at)
VALUES 
  ('adminSponsoredAdsPlacementProfile', 'en', 'Profile', NOW(), NOW()),
  ('adminSponsoredAdsPlacementProfile', 'es', 'Perfil', NOW(), NOW()),
  ('adminSponsoredAdsPlacementProfile', 'he', 'פרופיל', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- External ads dashboard - Profile placement label
INSERT INTO public.translations (key, locale, value, created_at, updated_at)
VALUES 
  ('adminSponsoredAdsPlacementProfileInline', 'en', 'Profile', NOW(), NOW()),
  ('adminSponsoredAdsPlacementProfileInline', 'es', 'Perfil', NOW(), NOW()),
  ('adminSponsoredAdsPlacementProfileInline', 'he', 'פרופיל', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Internal ads - mutual exclusivity subtitle
INSERT INTO public.translations (key, locale, value, created_at, updated_at)
VALUES 
  ('adminInternalAdsEnablingDisablesExternal', 'en', 'Enabling this will disable External ads', NOW(), NOW()),
  ('adminInternalAdsEnablingDisablesExternal', 'es', 'Activar esto desactivará los anuncios externos', NOW(), NOW()),
  ('adminInternalAdsEnablingDisablesExternal', 'he', 'הפעלת זה תבטל את המודעות החיצוניות', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- External ads - mutual exclusivity subtitle
INSERT INTO public.translations (key, locale, value, created_at, updated_at)
VALUES 
  ('adminExternalAdsEnablingDisablesInternal', 'en', 'Enabling this will disable Internal ads', NOW(), NOW()),
  ('adminExternalAdsEnablingDisablesInternal', 'es', 'Activar esto desactivará los anuncios internos', NOW(), NOW()),
  ('adminExternalAdsEnablingDisablesInternal', 'he', 'הפעלת זה תבטל את המודעות הפנימיות', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
