-- ============================================================================
-- Migration: Pinned-location error copy
-- ============================================================================
--
-- Translation keys for the server-side pin rejections introduced by
-- migration 20262087000000 (pinning only the server-observed position):
--   - pinNoObservedLocation: the user has no user_locations row (no live-GPS
--     observation on record), so there is nothing to pin.
--   - pinLocationTooOld: the last observed position is older than the
--     15-minute freshness window, so presence cannot be proven.
--
-- Consumed via ErrorLocalizationService.getErrorTranslationKey and the
-- pinned-location sheet (lib/widgets/pinned_location_sheet.dart). English
-- fallbacks also live in lib/providers/locale_provider.dart
-- (_defaultTranslations); these DB rows override them per locale.
--
-- Total: 2 keys x 3 locales (en, es, he) = 6 translation entries.
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: ENGLISH TRANSLATIONS (en)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('en', 'pinNoObservedLocation', 'No recent GPS position on the server to pin. Open the map with location on, then try again.', NOW(), NOW()),
('en', 'pinLocationTooOld', 'Your last known position is too old to pin. Turn location on briefly to update it, then try again.', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 2: SPANISH TRANSLATIONS (es)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('es', 'pinNoObservedLocation', 'No hay una posición GPS reciente en el servidor para fijar. Abre el mapa con la ubicación activada y vuelve a intentarlo.', NOW(), NOW()),
('es', 'pinLocationTooOld', 'Tu última posición conocida es demasiado antigua para fijarla. Activa la ubicación un momento para actualizarla y vuelve a intentarlo.', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 3: HEBREW TRANSLATIONS (he)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('he', 'pinNoObservedLocation', 'אין מיקום GPS אחרון בשרת לנעיצה. פתחו את המפה כשהמיקום פועל ונסו שוב.', NOW(), NOW()),
('he', 'pinLocationTooOld', 'המיקום האחרון הידוע שלכם ישן מדי לנעיצה. הפעילו מיקום לרגע כדי לעדכן אותו ונסו שוב.', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
