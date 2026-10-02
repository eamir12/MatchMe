-- ============================================================================
-- MatchMe Translation Backfill Script - Email Verification Section
-- ============================================================================
-- 
-- PURPOSE: Add translations for the Email Verification card in Security Center
--   - settingsEmailVerification (title)
--   - securityCenterStatusAvailable (status label)
--   - securityCenterEmailVerificationBody (main description)
--   - securityCenterEmailVerificationSecondary (secondary description with email)
--
-- LANGUAGES: English (fallback in code), Spanish (es), Hebrew (he)
--
-- EXECUTION NOTES:
--   - These keys are used in security_center_screen.dart
--   - Fallback is English from locale_provider.dart if translations missing
--   - Test with Spanish (es) and Hebrew (he) locales after execution
--
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
-- English - Email Verification
('en', 'settingsEmailVerification', 'Email Verification', NOW(), NOW()),
('en', 'securityCenterStatusAvailable', 'Available', NOW(), NOW()),
('en', 'securityCenterEmailVerificationBody', 'Use email verification as an alternative authentication method for sensitive actions', NOW(), NOW()),
('en', 'securityCenterEmailVerificationSecondary', 'Verification codes will be sent to {email}', NOW(), NOW()),

-- Spanish - Email Verification
('es', 'settingsEmailVerification', 'Verificación por Correo', NOW(), NOW()),
('es', 'securityCenterStatusAvailable', 'Disponible', NOW(), NOW()),
('es', 'securityCenterEmailVerificationBody', 'Usa verificación por correo electrónico como método de autenticación alternativo para acciones sensibles', NOW(), NOW()),
('es', 'securityCenterEmailVerificationSecondary', 'Se enviarán códigos de verificación a {email}', NOW(), NOW()),

-- Hebrew - Email Verification
('he', 'settingsEmailVerification', 'אימות דוא"ל', NOW(), NOW()),
('he', 'securityCenterStatusAvailable', 'זמין', NOW(), NOW()),
('he', 'securityCenterEmailVerificationBody', 'השתמש באימות דוא"ל כשיטת אימות חלופית עבור פעולות רגישות', NOW(), NOW()),
('he', 'securityCenterEmailVerificationSecondary', 'קודי אימות יישלחו אל {email}', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- ENGLISH FALLBACK VALUES (now in database - can be updated without release)
-- ============================================================================
-- These are now stored in the translations table with locale='en'
-- You can update them directly in the database without releasing a new version

-- ============================================================================
-- VERIFICATION QUERY - Run after insertion to verify coverage
-- ============================================================================
-- SELECT locale, COUNT(*) as translation_count FROM translations 
-- WHERE key IN (
--   'settingsEmailVerification',
--   'securityCenterStatusAvailable',
--   'securityCenterEmailVerificationBody',
--   'securityCenterEmailVerificationSecondary'
-- ) GROUP BY locale;

-- ============================================================================
-- END OF SCRIPT
-- ============================================================================
