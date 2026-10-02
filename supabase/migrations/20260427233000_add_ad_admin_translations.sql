-- Add translations for ad admin dashboard UI
-- Includes English, Spanish, and Hebrew translations

BEGIN;

-- Insert English translations
INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'adminAdvertisingTitle', 'Advertising', NOW(), NOW()),
  ('en', 'adminInternalSystemTab', 'Internal System', NOW(), NOW()),
  ('en', 'adminExternalSystemTab', 'External System', NOW(), NOW()),
  ('en', 'adminInternalAdsMasterControlsTitle', 'Master Controls', NOW(), NOW()),
  ('en', 'adminInternalAdsMasterControlsSubtitle', 'These settings control which placements, platforms, and tiers are allowed for all internal ads. Individual ads cannot override disabled options.', NOW(), NOW()),
  ('en', 'adminInternalAdsAllowedPlacements', 'Allowed Placements', NOW(), NOW()),
  ('en', 'adminInternalAdsAllowedPlatforms', 'Allowed Platforms', NOW(), NOW()),
  ('en', 'adminInternalAdsPlacementDisabledByMaster', 'Disabled by master controls. Enable in Ad Controls tab.', NOW(), NOW()),
  ('en', 'adminExternalAdsMetricActiveNetworks', 'Active Networks', NOW(), NOW()),
  ('en', 'adminExternalAdsNetworksSubtitle', 'Active ad networks and placements', NOW(), NOW()),
  ('en', 'adminExternalAdsNoNetworks', 'No ad networks configured yet', NOW(), NOW()),
  ('en', 'adminExternalAdsConfigureNetworksHint', 'Configure ad networks in the Ad Controls tab to enable external advertising.', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Insert Spanish translations
INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('es', 'adminAdvertisingTitle', 'Publicidad', NOW(), NOW()),
  ('es', 'adminInternalSystemTab', 'Sistema Interno', NOW(), NOW()),
  ('es', 'adminExternalSystemTab', 'Sistema Externo', NOW(), NOW()),
  ('es', 'adminInternalAdsMasterControlsTitle', 'Controles Maestros', NOW(), NOW()),
  ('es', 'adminInternalAdsMasterControlsSubtitle', 'Estas configuraciones controlan qué ubicaciones, plataformas y niveles están permitidos para todos los anuncios internos. Los anuncios individuales no pueden anular las opciones deshabilitadas.', NOW(), NOW()),
  ('es', 'adminInternalAdsAllowedPlacements', 'Ubicaciones Permitidas', NOW(), NOW()),
  ('es', 'adminInternalAdsAllowedPlatforms', 'Plataformas Permitidas', NOW(), NOW()),
  ('es', 'adminInternalAdsPlacementDisabledByMaster', 'Deshabilitado por controles maestros. Habilite en la pestaña Controles de Anuncios.', NOW(), NOW()),
  ('es', 'adminExternalAdsMetricActiveNetworks', 'Redes Activas', NOW(), NOW()),
  ('es', 'adminExternalAdsNetworksSubtitle', 'Redes y ubicaciones de anuncios activas', NOW(), NOW()),
  ('es', 'adminExternalAdsNoNetworks', 'Aún no hay redes de anuncios configuradas', NOW(), NOW()),
  ('es', 'adminExternalAdsConfigureNetworksHint', 'Configure redes de anuncios en la pestaña Controles de Anuncios para habilitar la publicidad externa.', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Insert Hebrew translations
INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('he', 'adminAdvertisingTitle', 'פרסום', NOW(), NOW()),
  ('he', 'adminInternalSystemTab', 'מערכת פנימית', NOW(), NOW()),
  ('he', 'adminExternalSystemTab', 'מערכת חיצונית', NOW(), NOW()),
  ('he', 'adminInternalAdsMasterControlsTitle', 'בקרות ראשיות', NOW(), NOW()),
  ('he', 'adminInternalAdsMasterControlsSubtitle', 'הגדרות אלה שולטות באילו מיקומים, פלטפורמות ודרגות מותרים לכל המודעות הפנימיות. מודעות בודדות לא יכולות לעקוף אפשרויות מושבתות.', NOW(), NOW()),
  ('he', 'adminInternalAdsAllowedPlacements', 'מיקומים מותרים', NOW(), NOW()),
  ('he', 'adminInternalAdsAllowedPlatforms', 'פלטפורמות מותרות', NOW(), NOW()),
  ('he', 'adminInternalAdsPlacementDisabledByMaster', 'מושבת על ידי בקרות ראשיות. הפעל בלשונית בקרות מודעות.', NOW(), NOW()),
  ('he', 'adminExternalAdsMetricActiveNetworks', 'רשתות פעילות', NOW(), NOW()),
  ('he', 'adminExternalAdsNetworksSubtitle', 'רשתות ומיקומי מודעות פעילים', NOW(), NOW()),
  ('he', 'adminExternalAdsNoNetworks', 'טרם הוגדרו רשתות מודעות', NOW(), NOW()),
  ('he', 'adminExternalAdsConfigureNetworksHint', 'הגדר רשתות מודעות בלשונית בקרות מודעות כדי לאפשר פרסום חיצוני.', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
