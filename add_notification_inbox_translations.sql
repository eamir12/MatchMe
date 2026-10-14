-- ============================================================================
-- MatchMe Translation Backfill Script - Notification Inbox
-- ============================================================================
--
-- PURPOSE: Add translation keys for the persistent notification inbox screen
--   (lib/screens/notifications/notification_inbox_screen.dart) and its entry
--   points (settings screen, main nav app bar bell).
--
--   Keys: inboxTitle, inboxEntryDesc, inboxUnreadCount, inboxEmptyTitle,
--   inboxEmptyMessage, inboxMarkAllRead, inboxDeleteAll,
--   inboxDeleteAllConfirm, inboxDelete, inboxOpenChat, and the per-type
--   labels inboxType*.
--
--   Total: 20 keys x 3 locales (en, es, he) = 60 translation entries
--
-- EXECUTION NOTES:
--   - Run in Supabase SQL Editor (or as part of migration pipeline).
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: ENGLISH TRANSLATIONS (en)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('en', 'inboxTitle', 'Notification Inbox', NOW(), NOW()),
('en', 'inboxEntryDesc', 'All your notifications in one place', NOW(), NOW()),
('en', 'inboxUnreadCount', '{count} unread', NOW(), NOW()),
('en', 'inboxEmptyTitle', 'No notifications yet', NOW(), NOW()),
('en', 'inboxEmptyMessage', 'Notifications you receive — new matches, messages, match expirations, announcements and more — will be saved here so you can read them anytime.', NOW(), NOW()),
('en', 'inboxMarkAllRead', 'Mark all as read', NOW(), NOW()),
('en', 'inboxDeleteAll', 'Delete all notifications', NOW(), NOW()),
('en', 'inboxDeleteAllConfirm', 'Delete every notification in your inbox? This cannot be undone.', NOW(), NOW()),
('en', 'inboxDelete', 'Delete', NOW(), NOW()),
('en', 'inboxOpenChat', 'Open chat', NOW(), NOW()),
('en', 'inboxTypeChatMessage', 'Chat message', NOW(), NOW()),
('en', 'inboxTypeNewMatch', 'New match', NOW(), NOW()),
('en', 'inboxTypeMatchExtended', 'Match extended', NOW(), NOW()),
('en', 'inboxTypeMatchExpiry', 'Match expiring', NOW(), NOW()),
('en', 'inboxTypePinnedExpiry', 'Pinned location expiring', NOW(), NOW()),
('en', 'inboxTypeAdminBroadcast', 'Announcement', NOW(), NOW()),
('en', 'inboxTypeLocationShare', 'Live location', NOW(), NOW()),
('en', 'inboxTypeBirthday', 'Birthday', NOW(), NOW()),
('en', 'inboxTypeVisibility', 'Visibility', NOW(), NOW()),
('en', 'inboxTypeGeneral', 'Notification', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 2: SPANISH TRANSLATIONS (es)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('es', 'inboxTitle', 'Bandeja de notificaciones', NOW(), NOW()),
('es', 'inboxEntryDesc', 'Todas tus notificaciones en un solo lugar', NOW(), NOW()),
('es', 'inboxUnreadCount', '{count} sin leer', NOW(), NOW()),
('es', 'inboxEmptyTitle', 'Aún no hay notificaciones', NOW(), NOW()),
('es', 'inboxEmptyMessage', 'Las notificaciones que recibas —nuevas coincidencias, mensajes, coincidencias por caducar, anuncios y más— se guardarán aquí para que puedas leerlas en cualquier momento.', NOW(), NOW()),
('es', 'inboxMarkAllRead', 'Marcar todo como leído', NOW(), NOW()),
('es', 'inboxDeleteAll', 'Eliminar todas las notificaciones', NOW(), NOW()),
('es', 'inboxDeleteAllConfirm', '¿Eliminar todas las notificaciones de tu bandeja? Esta acción no se puede deshacer.', NOW(), NOW()),
('es', 'inboxDelete', 'Eliminar', NOW(), NOW()),
('es', 'inboxOpenChat', 'Abrir chat', NOW(), NOW()),
('es', 'inboxTypeChatMessage', 'Mensaje de chat', NOW(), NOW()),
('es', 'inboxTypeNewMatch', 'Nueva coincidencia', NOW(), NOW()),
('es', 'inboxTypeMatchExtended', 'Coincidencia ampliada', NOW(), NOW()),
('es', 'inboxTypeMatchExpiry', 'Coincidencia por caducar', NOW(), NOW()),
('es', 'inboxTypePinnedExpiry', 'Ubicación fijada por caducar', NOW(), NOW()),
('es', 'inboxTypeAdminBroadcast', 'Anuncio', NOW(), NOW()),
('es', 'inboxTypeLocationShare', 'Ubicación en vivo', NOW(), NOW()),
('es', 'inboxTypeBirthday', 'Cumpleaños', NOW(), NOW()),
('es', 'inboxTypeVisibility', 'Visibilidad', NOW(), NOW()),
('es', 'inboxTypeGeneral', 'Notificación', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 3: HEBREW TRANSLATIONS (he)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('he', 'inboxTitle', 'תיבת ההתראות', NOW(), NOW()),
('he', 'inboxEntryDesc', 'כל ההתראות שלכם במקום אחד', NOW(), NOW()),
('he', 'inboxUnreadCount', '{count} שלא נקראו', NOW(), NOW()),
('he', 'inboxEmptyTitle', 'אין עדיין התראות', NOW(), NOW()),
('he', 'inboxEmptyMessage', 'ההתראות שתקבלו — התאמות חדשות, הודעות, התאמות שעומדות לפוג, הכרזות ועוד — יישמרו כאן כדי שתוכלו לקרוא אותן בכל עת.', NOW(), NOW()),
('he', 'inboxMarkAllRead', 'סמן הכל כנקרא', NOW(), NOW()),
('he', 'inboxDeleteAll', 'מחק את כל ההתראות', NOW(), NOW()),
('he', 'inboxDeleteAllConfirm', 'למחוק את כל ההתראות בתיבה? לא ניתן לבטל פעולה זו.', NOW(), NOW()),
('he', 'inboxDelete', 'מחק', NOW(), NOW()),
('he', 'inboxOpenChat', 'פתח צ׳אט', NOW(), NOW()),
('he', 'inboxTypeChatMessage', 'הודעת צ׳אט', NOW(), NOW()),
('he', 'inboxTypeNewMatch', 'התאמה חדשה', NOW(), NOW()),
('he', 'inboxTypeMatchExtended', 'התאמה הוארכה', NOW(), NOW()),
('he', 'inboxTypeMatchExpiry', 'התאמה עומדת לפוג', NOW(), NOW()),
('he', 'inboxTypePinnedExpiry', 'הנעיצה עומדת לפוג', NOW(), NOW()),
('he', 'inboxTypeAdminBroadcast', 'הכרזה', NOW(), NOW()),
('he', 'inboxTypeLocationShare', 'מיקום חי', NOW(), NOW()),
('he', 'inboxTypeBirthday', 'יום הולדת', NOW(), NOW()),
('he', 'inboxTypeVisibility', 'נראות', NOW(), NOW()),
('he', 'inboxTypeGeneral', 'התראה', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
