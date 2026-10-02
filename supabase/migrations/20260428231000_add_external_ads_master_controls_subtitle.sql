-- Add external ads master controls subtitle translation
BEGIN;

-- Insert English translations
INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'adminExternalAdsMasterControlsSubtitle', 'Enable or disable external ad system', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Insert Spanish translations
INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('es', 'adminExternalAdsMasterControlsSubtitle', 'Habilitar o deshabilitar el sistema de anuncios externos', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Insert Hebrew translations
INSERT INTO public.translations (locale, key, value, created_at, updated_at)
VALUES
  ('he', 'adminExternalAdsMasterControlsSubtitle', 'אפשר או השבת את מערכת המודעות החיצונית', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
