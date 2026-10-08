-- ============================================================================
-- Migration: settings section-header copy
-- ============================================================================
--
-- Translation keys for the Settings screen's regrouped section headers
-- (lib/screens/settings/settings_screen.dart):
--
--   - settingsSectionGeneral   ("General"): used in the settings search
--     sheet for destinations that have no group header on the main list
--     (App display, Terms of Service, Privacy Policy).
--   - settingsSectionMatching  ("Matching & discovery"): Matching, Match
--     Preferences and Invisibility Rules.
--   - settingsSectionPremium   ("Premium"): MatchMe Premium, Billing and
--     Invite Friends. Replaces the previous header, which reused the
--     paywallTitle marketing string.
--   - settingsSectionAccount   ("Account"): Profile Verification, Security
--     & Sign-In and Account Management. These previously sat under a
--     "Profile Verification" header they did not belong to.
--
-- Total: 4 keys x 3 locales (en, es, he) = 12 translation entries.
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: ENGLISH TRANSLATIONS (en)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('en', 'settingsSectionAccount', 'Account', NOW(), NOW()),
('en', 'settingsSectionGeneral', 'General', NOW(), NOW()),
('en', 'settingsSectionMatching', 'Matching & discovery', NOW(), NOW()),
('en', 'settingsSectionPremium', 'Premium', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 2: SPANISH TRANSLATIONS (es)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('es', 'settingsSectionAccount', 'Cuenta', NOW(), NOW()),
('es', 'settingsSectionGeneral', 'General', NOW(), NOW()),
('es', 'settingsSectionMatching', 'Coincidencias y descubrimiento', NOW(), NOW()),
('es', 'settingsSectionPremium', 'Premium', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 3: HEBREW TRANSLATIONS (he)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('he', 'settingsSectionAccount', 'חשבון', NOW(), NOW()),
('he', 'settingsSectionGeneral', 'כללי', NOW(), NOW()),
('he', 'settingsSectionMatching', 'התאמות וגילוי', NOW(), NOW()),
('he', 'settingsSectionPremium', 'פרימיום', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
