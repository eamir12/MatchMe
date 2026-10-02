-- ============================================================================
-- MatchMe Translation Backfill Script - Calendar Import (Desktop)
--
-- PURPOSE: Add the translation key for the device-calendar availability guard.
--   - calendarSyncDeviceNotSupported (1 key)
--   Total: 1 key x 3 locales (en, es, he) = 3 translation entries
--
-- WHY:
--   `device_calendar_plus` ships Android and iOS implementations only. The
--   device-calendar import option used to be gated on `!kIsWeb`, so on web,
--   Windows, macOS and Linux the app offered an import that could only fail with
--   `Bad state: DeviceCalendarPlusPlatform.instance has not been initialized`.
--   The option is now hidden on those platforms, and
--   CalendarSyncService.requestPermissions() throws this key if a device
--   calendar is requested anyway.
--
--   The English fallback lives in lib/providers/locale_provider.dart, so the
--   screen is usable before this runs. Without it the key is reported by the
--   "Missing DB translation keys" bootstrap diagnostic for `en`.
--
-- EXECUTION NOTES:
--   - Run against the Supabase project used by the app.
--   - Verify with the English, Spanish (es) and Hebrew (he) locales.
--   - On a fresh sign-in the app logs the count of keys still missing from the
--     DB; this key should no longer appear in that list.
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: ENGLISH TRANSLATIONS (en)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('en', 'calendarSyncDeviceNotSupported', 'Importing from your device calendar is only available on the mobile app. Use Google, Outlook or Apple Calendar instead.', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 2: SPANISH TRANSLATIONS (es)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('es', 'calendarSyncDeviceNotSupported', 'Importar desde el calendario del dispositivo solo está disponible en la app móvil. Usa Google, Outlook o Calendario de Apple.', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 3: HEBREW TRANSLATIONS (he)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('he', 'calendarSyncDeviceNotSupported', 'ייבוא מהיומן של המכשיר זמין רק באפליקצייה לנייד. אפשר להשתמש ב-Google, ב-Outlook או ביומן Apple.', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- VERIFICATION
-- ============================================================================

-- SELECT locale, key, value
-- FROM translations
-- WHERE key = 'calendarSyncDeviceNotSupported'
-- ORDER BY locale, key;
--
-- Expected result: 3 rows (en, es, he)
-- ============================================================================
