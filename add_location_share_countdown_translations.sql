-- ============================================================================
-- MatchMe Translation Backfill Script - Location Share Countdown
-- ============================================================================
--
-- PURPOSE: Add missing translation keys for Location Share countdown timer
--   - locationShareCountdownMinutes: 'for another {minutes} minutes and {seconds} seconds'
--   - locationShareCountdownHours: 'for another {hours} hours and {minutes} minutes'
--   Total: 2 keys -- 3 locales (en, es, he) = 6 translation entries
--
-- EXECUTION NOTES:
--   - These keys are already in locale_provider.dart defaults (lines 1519-1520)
--   - Only missing from Supabase 'translations' table causing startup warning
--   - Run in Supabase SQL Editor
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: ENGLISH TRANSLATIONS (en)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('en', 'locationShareCountdownMinutes', 'for another {minutes} minutes and {seconds} seconds', NOW(), NOW()),
('en', 'locationShareCountdownHours', 'for another {hours} hours and {minutes} minutes', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 2: SPANISH TRANSLATIONS (es)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('es', 'locationShareCountdownMinutes', 'por otros {minutes} minutos y {seconds} segundos', NOW(), NOW()),
('es', 'locationShareCountdownHours', 'por otras {hours} horas y {minutes} minutos', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 3: HEBREW TRANSLATIONS (he)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('he', 'locationShareCountdownMinutes', 'לעוד {minutes} דקות ו-{seconds} שניות', NOW(), NOW()),
('he', 'locationShareCountdownHours', 'לעוד {hours} שעות ו-{minutes} דקות', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- VERIFICATION QUERY
-- ============================================================================
-- Run this after the INSERT to verify all translations were added:
--
-- SELECT locale, key, value
-- FROM translations
-- WHERE key IN (
--   'locationShareCountdownMinutes',
--   'locationShareCountdownHours'
-- )
-- ORDER BY locale, key;
--
-- Expected result: 6 rows (2 keys -- 3 locales)
-- ============================================================================
