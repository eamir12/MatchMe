BEGIN;

-- Add translations for external ads configuration sections
-- Reusing existing keys where possible to maintain consistency
INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'adminExternalAdsTierConfigTitle', 'User Tiers', NOW(), NOW()),
  ('en', 'adminExternalAdsTierConfigSubtitle', 'Select which subscription tiers can see external ads', NOW(), NOW()),
  ('en', 'adminExternalAdsPlatformConfigTitle', 'Platforms', NOW(), NOW()),
  ('en', 'adminExternalAdsPlatformConfigSubtitle', 'Select which platforms can display external ads', NOW(), NOW()),
  ('en', 'adminExternalAdsPlacementConfigTitle', 'Placements', NOW(), NOW()),
  ('en', 'adminExternalAdsPlacementConfigSubtitle', 'Select where external ads can appear', NOW(), NOW()),
  ('en', 'adminExternalAdsAnalyticsByNetwork', 'Analytics by Network', NOW(), NOW()),
  ('en', 'adminExternalAdsAnalyticsByPlacement', 'Analytics by Placement', NOW(), NOW()),
  ('en', 'adminExternalAdsAnalyticsByPlatform', 'Analytics by Platform', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('es', 'adminExternalAdsTierConfigTitle', 'Niveles de Usuario', NOW(), NOW()),
  ('es', 'adminExternalAdsTierConfigSubtitle', 'Selecciona qué niveles de suscripción pueden ver anuncios externos', NOW(), NOW()),
  ('es', 'adminExternalAdsPlatformConfigTitle', 'Plataformas', NOW(), NOW()),
  ('es', 'adminExternalAdsPlatformConfigSubtitle', 'Selecciona qué plataformas pueden mostrar anuncios externos', NOW(), NOW()),
  ('es', 'adminExternalAdsPlacementConfigTitle', 'Ubicaciones', NOW(), NOW()),
  ('es', 'adminExternalAdsPlacementConfigSubtitle', 'Selecciona dónde pueden aparecer los anuncios externos', NOW(), NOW()),
  ('es', 'adminExternalAdsAnalyticsByNetwork', 'Análisis por Red', NOW(), NOW()),
  ('es', 'adminExternalAdsAnalyticsByPlacement', 'Análisis por Ubicación', NOW(), NOW()),
  ('es', 'adminExternalAdsAnalyticsByPlatform', 'Análisis por Plataforma', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('he', 'adminExternalAdsTierConfigTitle', 'רמות משתמש', NOW(), NOW()),
  ('he', 'adminExternalAdsTierConfigSubtitle', 'בחר אילו רמות מנוי יכולות לראות מודעות חיצוניות', NOW(), NOW()),
  ('he', 'adminExternalAdsPlatformConfigTitle', 'פלטפורמות', NOW(), NOW()),
  ('he', 'adminExternalAdsPlatformConfigSubtitle', 'בחר אילו פלטפורמות יכולות להציג מודעות חיצוניות', NOW(), NOW()),
  ('he', 'adminExternalAdsPlacementConfigTitle', 'מיקומים', NOW(), NOW()),
  ('he', 'adminExternalAdsPlacementConfigSubtitle', 'בחר היכן יכולות להופיע מודעות חיצוניות', NOW(), NOW()),
  ('he', 'adminExternalAdsAnalyticsByNetwork', 'ניתוח לפי רשת', NOW(), NOW()),
  ('he', 'adminExternalAdsAnalyticsByPlacement', 'ניתוח לפי מיקום', NOW(), NOW()),
  ('he', 'adminExternalAdsAnalyticsByPlatform', 'ניתוח לפי פלטפורמה', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
