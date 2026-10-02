-- ============================================================================
-- MatchMe Translation Backfill Script - Location Share Live Countdown
-- ============================================================================
--
-- PURPOSE: Add translation key for the per-second live countdown shown in
--   location share notifications:
--   - locationShareCountdownHoursSeconds: 'for another {hours} hours, {minutes} minutes and {seconds} seconds'
--   Total: 1 key -- 3 locales (en, es, he) = 3 translation entries
--
-- EXECUTION NOTES:
--   - This key is already in locale_provider.dart defaults
--   - Only missing from Supabase 'translations' table causing startup warning
--   - Run in Supabase SQL Editor
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: ENGLISH TRANSLATIONS (en)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('en', 'locationShareCountdownHoursSeconds', 'for another {hours} hours, {minutes} minutes and {seconds} seconds', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 2: SPANISH TRANSLATIONS (es)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('es', 'locationShareCountdownHoursSeconds', 'por otras {hours} horas, {minutes} minutos y {seconds} segundos', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 3: HEBREW TRANSLATIONS (he)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('he', 'locationShareCountdownHoursSeconds', 'לעוד {hours} שעות, {minutes} דקות ו-{seconds} שניות', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- VERIFICATION QUERY
-- ============================================================================
-- SELECT locale, key, value
-- FROM translations
-- WHERE key = 'locationShareCountdownHoursSeconds'
-- ORDER BY locale;
--
-- Expected result: 3 rows (1 key -- 3 locales)
-- ============================================================================
