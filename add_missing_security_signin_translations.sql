-- ============================================================================
-- MatchMe Translation Backfill Script - Security Sign-In Screen
-- ============================================================================
-- 
-- PURPOSE: Add missing translation keys for Security Sign-In Screen
--   - securitySignInHubTitle (1 key)
--   - settingsMfaUpdate (1 key)
--   - generalOk (1 key)
--   - generalVerify (1 key)
--   - generalFieldRequired (1 key)
--   - settingsMfaOpenAuthenticator (1 key)
--   - settingsMfaOpenAuthenticatorBody (1 key)
--   Total: 7 keys × 3 locales (en, es, he) = 21 translation entries
--
-- EXECUTION NOTES:
--   - These keys are used in security_sign_in_screen.dart and settings_screen.dart
--   - English fallbacks are missing from locale_provider.dart
--   - Spanish and Hebrew translations are missing from Supabase
--   - Test with English, Spanish (es), and Hebrew (he) locales after execution
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: ENGLISH TRANSLATIONS (en)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('en', 'securitySignInHubTitle', 'Security & Sign-In', NOW(), NOW()),
('en', 'settingsMfaUpdate', 'Update 2FA', NOW(), NOW()),
('en', 'generalOk', 'OK', NOW(), NOW()),
('en', 'generalVerify', 'Verify', NOW(), NOW()),
('en', 'generalFieldRequired', 'This field is required', NOW(), NOW()),
('en', 'settingsMfaOpenAuthenticator', 'Open Authenticator App', NOW(), NOW()),
('en', 'settingsMfaOpenAuthenticatorBody', 'Open your authenticator app to add this account', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 2: SPANISH TRANSLATIONS (es)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('es', 'securitySignInHubTitle', 'Seguridad e Inicio de Sesión', NOW(), NOW()),
('es', 'settingsMfaUpdate', 'Actualizar 2FA', NOW(), NOW()),
('es', 'generalOk', 'Aceptar', NOW(), NOW()),
('es', 'generalVerify', 'Verificar', NOW(), NOW()),
('es', 'generalFieldRequired', 'Este campo es obligatorio', NOW(), NOW()),
('es', 'settingsMfaOpenAuthenticator', 'Abrir Aplicación Autenticadora', NOW(), NOW()),
('es', 'settingsMfaOpenAuthenticatorBody', 'Abre tu aplicación autenticadora para agregar esta cuenta', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 3: HEBREW TRANSLATIONS (he)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('he', 'securitySignInHubTitle', 'אבטחה וכניסה', NOW(), NOW()),
('he', 'settingsMfaUpdate', 'עדכן 2FA', NOW(), NOW()),
('he', 'generalOk', 'אישור', NOW(), NOW()),
('he', 'generalVerify', 'אימות', NOW(), NOW()),
('he', 'generalFieldRequired', 'שדה זה נדרש', NOW(), NOW()),
('he', 'settingsMfaOpenAuthenticator', 'פתח אפליקציית מאמת', NOW(), NOW()),
('he', 'settingsMfaOpenAuthenticatorBody', 'פתח את אפליקציית המאמת שלך כדי להוסיף חשבון זה', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- VERIFICATION QUERY
-- ============================================================================
-- Run this after the INSERT to verify all translations were added:
--
-- SELECT locale, key, value 
-- FROM translations 
-- WHERE key IN (
--   'securitySignInHubTitle',
--   'settingsMfaUpdate',
--   'generalOk',
--   'generalVerify',
--   'generalFieldRequired',
--   'settingsMfaOpenAuthenticator',
--   'settingsMfaOpenAuthenticatorBody'
-- )
-- ORDER BY locale, key;
--
-- Expected result: 21 rows (7 keys × 3 locales)
-- ============================================================================
