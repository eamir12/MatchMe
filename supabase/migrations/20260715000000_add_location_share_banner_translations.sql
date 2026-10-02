-- Add location share banner translation keys
-- Run this in Supabase SQL Editor

BEGIN;

-- English translations
INSERT INTO translations (key, value, locale) VALUES
  ('locationShareBannerTitle', 'Live Location Active', 'en'),
  ('locationShareBannerSubtitle', 'Tap to view on map', 'en'),
  ('locationShareBannerWaiting', 'Waiting for location...', 'en'),
  ('locationShareBannerView', 'View', 'en'),
  ('locationShareBannerYouAreSharing', 'You are sharing your location', 'en'),
  ('locationShareBannerSharingWith', 'Sharing with {name}', 'en'),
  ('locationShareBannerLocating', 'Getting your location...', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (key, value, locale) VALUES
  ('locationShareBannerTitle', 'Ubicación en vivo activa', 'es'),
  ('locationShareBannerSubtitle', 'Toca para ver en el mapa', 'es'),
  ('locationShareBannerWaiting', 'Esperando ubicación...', 'es'),
  ('locationShareBannerView', 'Ver', 'es'),
  ('locationShareBannerYouAreSharing', 'Estás compartiendo tu ubicación', 'es'),
  ('locationShareBannerSharingWith', 'Compartiendo con {name}', 'es'),
  ('locationShareBannerLocating', 'Obteniendo tu ubicación...', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (key, value, locale) VALUES
  ('locationShareBannerTitle', 'שיתוף מיקום פעיל', 'he'),
  ('locationShareBannerSubtitle', 'לחץ כדי לצפות במפה', 'he'),
  ('locationShareBannerWaiting', 'ממתין למיקום...', 'he'),
  ('locationShareBannerView', 'צפה', 'he'),
  ('locationShareBannerYouAreSharing', 'אתה משתף את המיקום שלך', 'he'),
  ('locationShareBannerSharingWith', 'משתף עם {name}', 'he'),
  ('locationShareBannerLocating', 'מקבל את המיקום שלך...', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
