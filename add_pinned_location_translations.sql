-- ============================================================================
-- MatchMe Translation Backfill Script - Pinned Home-Base Location
-- ============================================================================
--
-- PURPOSE: Add translation keys for the pinned home-base location feature
--   App UI (24 keys, also in locale_provider.dart EN defaults = code fallback):
--     pinnedLocationSectionTitle, pinnedLocationSectionDesc,
--     pinnedLocationPinAction, pinnedLocationActiveUntil,
--     pinnedLocationRemaining, pinnedLocationRemainingDays,
--     pinnedLocationRemainingHours, pinnedLocationRemainingMinutes,
--     pinnedLocationExtend, pinnedLocationUnpin, pinnedLocationLabelHint,
--     pinnedLocationDuration, pinnedLocationDur24h, pinnedLocationDur3d,
--     pinnedLocationDur7d, pinnedLocationDur14d, pinnedLocationDur30d,
--     pinnedLocationManage, pinnedLocationBanner, pinnedLocationExpired,
--     pinnedLocationPinned, pinnedLocationExtended, pinnedLocationUnpinned,
--     pinnedLocationNoPosition, pinnedPartnerBadge
--   Server push copy (3 keys, EN fallback in cron-jobs/_translationFallbacks):
--     pinnedExpiryTitle, pinnedExpiryBodyMinutes, pinnedExpiryBodyHours
--   Total: 28 keys x 3 locales (en, es, he) = 84 translation entries
--
-- EXECUTION NOTES:
--   - Run in Supabase SQL Editor
--   - Placeholders ({label}, {date}, {count}, {duration}, {labelPart}) must
--     be preserved verbatim in every locale.
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: ENGLISH TRANSLATIONS (en)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('en', 'pinnedLocationSectionTitle', 'Home base (pinned location)', NOW(), NOW()),
('en', 'pinnedLocationSectionDesc', 'Keep matching near home while you travel. GPS pauses and matches use your pinned spot until it expires.', NOW(), NOW()),
('en', 'pinnedLocationPinAction', 'Pin current location', NOW(), NOW()),
('en', 'pinnedLocationActiveUntil', 'Pinned{label} until {date}', NOW(), NOW()),
('en', 'pinnedLocationRemaining', '{duration} left', NOW(), NOW()),
('en', 'pinnedLocationRemainingDays', '{count}d', NOW(), NOW()),
('en', 'pinnedLocationRemainingHours', '{count}h', NOW(), NOW()),
('en', 'pinnedLocationRemainingMinutes', '{count}m', NOW(), NOW()),
('en', 'pinnedLocationExtend', 'Add time', NOW(), NOW()),
('en', 'pinnedLocationUnpin', 'Unpin now', NOW(), NOW()),
('en', 'pinnedLocationLabelHint', 'Label (optional, e.g. Home)', NOW(), NOW()),
('en', 'pinnedLocationDuration', 'Pin for', NOW(), NOW()),
('en', 'pinnedLocationDur24h', '24 hours', NOW(), NOW()),
('en', 'pinnedLocationDur3d', '3 days', NOW(), NOW()),
('en', 'pinnedLocationDur7d', '7 days', NOW(), NOW()),
('en', 'pinnedLocationDur14d', '14 days', NOW(), NOW()),
('en', 'pinnedLocationDur30d', '30 days', NOW(), NOW()),
('en', 'pinnedLocationManage', 'Manage', NOW(), NOW()),
('en', 'pinnedLocationBanner', '📍 Matching from pinned spot{label} — GPS paused', NOW(), NOW()),
('en', 'pinnedLocationExpired', 'Pinned location expired — live GPS resumed.', NOW(), NOW()),
('en', 'pinnedLocationPinned', 'Location pinned until {date}.', NOW(), NOW()),
('en', 'pinnedLocationExtended', 'Pinned time extended until {date}.', NOW(), NOW()),
('en', 'pinnedLocationUnpinned', 'Pin removed — live GPS resumed.', NOW(), NOW()),
('en', 'pinnedPartnerBadge', '🏠 Home base', NOW(), NOW()),
('en', 'pinnedLocationNoPosition', 'No recent position to pin yet. Turn location on briefly, then try again.', NOW(), NOW()),
('en', 'pinnedExpiryTitle', 'Pinned location expiring soon', NOW(), NOW()),
('en', 'pinnedExpiryBodyMinutes', 'Your pinned location{labelPart} expires in {count} minutes. Open the app to add more time.', NOW(), NOW()),
('en', 'pinnedExpiryBodyHours', 'Your pinned location{labelPart} expires in {count} hours. Open the app to add more time.', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 2: SPANISH TRANSLATIONS (es)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('es', 'pinnedLocationSectionTitle', 'Base (ubicación fijada)', NOW(), NOW()),
('es', 'pinnedLocationSectionDesc', 'Sigue recibiendo matches cerca de casa mientras viajas. El GPS se pausa y los matches usan tu punto fijado hasta que caduque.', NOW(), NOW()),
('es', 'pinnedLocationPinAction', 'Fijar ubicación actual', NOW(), NOW()),
('es', 'pinnedLocationActiveUntil', 'Fijada{label} hasta el {date}', NOW(), NOW()),
('es', 'pinnedLocationRemaining', '{duration} restantes', NOW(), NOW()),
('es', 'pinnedLocationRemainingDays', '{count} d', NOW(), NOW()),
('es', 'pinnedLocationRemainingHours', '{count} h', NOW(), NOW()),
('es', 'pinnedLocationRemainingMinutes', '{count} min', NOW(), NOW()),
('es', 'pinnedLocationExtend', 'Añadir tiempo', NOW(), NOW()),
('es', 'pinnedLocationUnpin', 'Quitar fijación', NOW(), NOW()),
('es', 'pinnedLocationLabelHint', 'Etiqueta (opcional, p. ej. Casa)', NOW(), NOW()),
('es', 'pinnedLocationDuration', 'Fijar por', NOW(), NOW()),
('es', 'pinnedLocationDur24h', '24 horas', NOW(), NOW()),
('es', 'pinnedLocationDur3d', '3 días', NOW(), NOW()),
('es', 'pinnedLocationDur7d', '7 días', NOW(), NOW()),
('es', 'pinnedLocationDur14d', '14 días', NOW(), NOW()),
('es', 'pinnedLocationDur30d', '30 días', NOW(), NOW()),
('es', 'pinnedLocationManage', 'Gestionar', NOW(), NOW()),
('es', 'pinnedLocationBanner', '📍 Matches desde el punto fijado{label} — GPS en pausa', NOW(), NOW()),
('es', 'pinnedLocationExpired', 'La fijación caducó — GPS en vivo reanudado.', NOW(), NOW()),
('es', 'pinnedLocationPinned', 'Ubicación fijada hasta el {date}.', NOW(), NOW()),
('es', 'pinnedLocationExtended', 'Tiempo de fijación ampliado hasta el {date}.', NOW(), NOW()),
('es', 'pinnedLocationUnpinned', 'Fijación eliminada — GPS en vivo reanudado.', NOW(), NOW()),
('es', 'pinnedPartnerBadge', '🏠 Base', NOW(), NOW()),
('es', 'pinnedLocationNoPosition', 'Aún no hay posición reciente para fijar. Activa la ubicación un momento e inténtalo de nuevo.', NOW(), NOW()),
('es', 'pinnedExpiryTitle', 'Tu ubicación fijada está por caducar', NOW(), NOW()),
('es', 'pinnedExpiryBodyMinutes', 'Tu ubicación fijada{labelPart} caduca en {count} minutos. Abre la app para añadir más tiempo.', NOW(), NOW()),
('es', 'pinnedExpiryBodyHours', 'Tu ubicación fijada{labelPart} caduca en {count} horas. Abre la app para añadir más tiempo.', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 3: HEBREW TRANSLATIONS (he)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('he', 'pinnedLocationSectionTitle', 'בסיס (מיקום נעוץ)', NOW(), NOW()),
('he', 'pinnedLocationSectionDesc', 'המשיכו לקבל התאמות ליד הבית בזמן נסיעה. ה-GPS מושהה וההתאמות משתמשות בנקודה הנעוצה עד לפקיעה.', NOW(), NOW()),
('he', 'pinnedLocationPinAction', 'נעצו את המיקום הנוכחי', NOW(), NOW()),
('he', 'pinnedLocationActiveUntil', 'נעוץ{label} עד {date}', NOW(), NOW()),
('he', 'pinnedLocationRemaining', '{duration}', NOW(), NOW()),
('he', 'pinnedLocationRemainingDays', 'נותרו {count} ימים', NOW(), NOW()),
('he', 'pinnedLocationRemainingHours', 'נותרו {count} שע׳', NOW(), NOW()),
('he', 'pinnedLocationRemainingMinutes', 'נותרו {count} דק׳', NOW(), NOW()),
('he', 'pinnedLocationExtend', 'הוסיפו זמן', NOW(), NOW()),
('he', 'pinnedLocationUnpin', 'בטלו את הנעיצה', NOW(), NOW()),
('he', 'pinnedLocationLabelHint', 'תווית (אופציונלי, למשל בית)', NOW(), NOW()),
('he', 'pinnedLocationDuration', 'נעיצה למשך', NOW(), NOW()),
('he', 'pinnedLocationDur24h', '24 שעות', NOW(), NOW()),
('he', 'pinnedLocationDur3d', '3 ימים', NOW(), NOW()),
('he', 'pinnedLocationDur7d', '7 ימים', NOW(), NOW()),
('he', 'pinnedLocationDur14d', '14 ימים', NOW(), NOW()),
('he', 'pinnedLocationDur30d', '30 ימים', NOW(), NOW()),
('he', 'pinnedLocationManage', 'ניהול', NOW(), NOW()),
('he', 'pinnedLocationBanner', '📍 התאמות מהנקודה הנעוצה{label} — ה-GPS מושהה', NOW(), NOW()),
('he', 'pinnedLocationExpired', 'הנעיצה פגה — ה-GPS החי חזר לפעול.', NOW(), NOW()),
('he', 'pinnedLocationPinned', 'המיקום ננעץ עד {date}.', NOW(), NOW()),
('he', 'pinnedLocationExtended', 'זמן הנעיצה הוארך עד {date}.', NOW(), NOW()),
('he', 'pinnedLocationUnpinned', 'הנעיצה הוסרה — ה-GPS החי חזר לפעול.', NOW(), NOW()),
('he', 'pinnedPartnerBadge', '🏠 בסיס', NOW(), NOW()),
('he', 'pinnedLocationNoPosition', 'אין עדיין מיקום עדכני לנעיצה. הפעילו מיקום לרגע ונסו שוב.', NOW(), NOW()),
('he', 'pinnedExpiryTitle', 'הנעיצה עומדת לפוג', NOW(), NOW()),
('he', 'pinnedExpiryBodyMinutes', 'המיקום הנעוץ{labelPart} יפוג בעוד {count} דקות. פתחו את האפליקציה כדי להוסיף זמן.', NOW(), NOW()),
('he', 'pinnedExpiryBodyHours', 'המיקום הנעוץ{labelPart} יפוג בעוד {count} שעות. פתחו את האפליקציה כדי להוסיף זמן.', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- VERIFICATION QUERY
-- ============================================================================
-- Run this after the INSERTs to verify all translations were added:
--
-- SELECT locale, key, value
-- FROM translations
-- WHERE key LIKE 'pinned%'
-- ORDER BY key, locale;
--
-- Expected result: 84 rows (28 keys x 3 locales)
-- ============================================================================
