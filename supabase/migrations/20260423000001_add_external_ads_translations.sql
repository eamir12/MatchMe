-- Add translations for external ads system
-- These are new keys specific to external ads that don't have equivalents in the internal system

BEGIN;

-- Insert English translations
INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'adminExternalAdsRecentEvents', 'Recent Events', NOW(), NOW()),
  ('en', 'adminExternalAdsEventType', 'Event Type', NOW(), NOW()),
  ('en', 'adminExternalAdsTimestamp', 'Timestamp', NOW(), NOW()),
  ('en', 'adminExternalAdsUser', 'User', NOW(), NOW()),
  ('en', 'adminExternalAdsMetricEvents', 'Events', NOW(), NOW()),
  ('en', 'adminExternalAdsConfigEnabled', 'External ads enabled', NOW(), NOW()),
  ('en', 'adminExternalAdsRateLimitingTitle', 'Rate Limiting', NOW(), NOW()),
  ('en', 'adminExternalAdsRateLimitPerUser', 'Maximum ads per user per day', NOW(), NOW()),
  ('en', 'adminExternalAdsRateLimitPerHour', 'Maximum ads per user per hour', NOW(), NOW()),
  ('en', 'adminExternalAdsPlacementBannerTop', 'Top banner', NOW(), NOW()),
  ('en', 'adminExternalAdsPlacementBannerBottom', 'Bottom banner', NOW(), NOW()),
  ('en', 'adminExternalAdsPlacementInterstitial', 'Interstitial', NOW(), NOW()),
  ('en', 'adminExternalAdsPlacementRewarded', 'Rewarded', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Insert Spanish translations
INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('es', 'adminExternalAdsRecentEvents', 'Eventos Recientes', NOW(), NOW()),
  ('es', 'adminExternalAdsEventType', 'Tipo de Evento', NOW(), NOW()),
  ('es', 'adminExternalAdsTimestamp', 'Marca de Tiempo', NOW(), NOW()),
  ('es', 'adminExternalAdsUser', 'Usuario', NOW(), NOW()),
  ('es', 'adminExternalAdsMetricEvents', 'Eventos', NOW(), NOW()),
  ('es', 'adminExternalAdsConfigEnabled', 'Anuncios externos habilitados', NOW(), NOW()),
  ('es', 'adminExternalAdsRateLimitingTitle', 'Límite de Velocidad', NOW(), NOW()),
  ('es', 'adminExternalAdsRateLimitPerUser', 'Máximo de anuncios por usuario por día', NOW(), NOW()),
  ('es', 'adminExternalAdsRateLimitPerHour', 'Máximo de anuncios por usuario por hora', NOW(), NOW()),
  ('es', 'adminExternalAdsPlacementBannerTop', 'Banner superior', NOW(), NOW()),
  ('es', 'adminExternalAdsPlacementBannerBottom', 'Banner inferior', NOW(), NOW()),
  ('es', 'adminExternalAdsPlacementInterstitial', 'Intersticial', NOW(), NOW()),
  ('es', 'adminExternalAdsPlacementRewarded', 'Recompensado', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Insert Hebrew translations
INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('he', 'adminExternalAdsRecentEvents', 'אירועים אחרונים', NOW(), NOW()),
  ('he', 'adminExternalAdsEventType', 'סוג אירוע', NOW(), NOW()),
  ('he', 'adminExternalAdsTimestamp', 'חותמת זמן', NOW(), NOW()),
  ('he', 'adminExternalAdsUser', 'משתמש', NOW(), NOW()),
  ('he', 'adminExternalAdsMetricEvents', 'אירועים', NOW(), NOW()),
  ('he', 'adminExternalAdsConfigEnabled', 'מודעות חיצוניות מופעלות', NOW(), NOW()),
  ('he', 'adminExternalAdsRateLimitingTitle', 'הגבלת קצב', NOW(), NOW()),
  ('he', 'adminExternalAdsRateLimitPerUser', 'מקסימום מודעות לכל משתמש ליום', NOW(), NOW()),
  ('he', 'adminExternalAdsRateLimitPerHour', 'מקסימום מודעות לכל משתמש לשעה', NOW(), NOW()),
  ('he', 'adminExternalAdsPlacementBannerTop', 'באנר עליון', NOW(), NOW()),
  ('he', 'adminExternalAdsPlacementBannerBottom', 'באנר תחתון', NOW(), NOW()),
  ('he', 'adminExternalAdsPlacementInterstitial', 'בין-דפי', NOW(), NOW()),
  ('he', 'adminExternalAdsPlacementRewarded', 'מתוגמל', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
