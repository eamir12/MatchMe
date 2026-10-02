-- Add missing translation keys for external ads analytics drill-down table
-- These keys are used in the admin dashboard but were missing from translations

BEGIN;

-- Insert English translations
INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'adminExternalAdsRevenue', 'Revenue', NOW(), NOW()),
  ('en', 'adminExternalAdsCtr', 'CTR', NOW(), NOW()),
  ('en', 'adminExternalAdsCpm', 'CPM', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Insert Spanish translations
INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('es', 'adminExternalAdsRevenue', 'Ingresos', NOW(), NOW()),
  ('es', 'adminExternalAdsCtr', 'CTR', NOW(), NOW()),
  ('es', 'adminExternalAdsCpm', 'CPM', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Insert Hebrew translations
INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('he', 'adminExternalAdsRevenue', 'הכנסות', NOW(), NOW()),
  ('he', 'adminExternalAdsCtr', 'CTR', NOW(), NOW()),
  ('he', 'adminExternalAdsCpm', 'CPM', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
