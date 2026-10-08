-- ============================================================================
-- Migration: multi-select & chat-archive copy
-- ============================================================================
--
-- Translation keys for:
--   - Notification-inbox multi-select (lib/screens/notifications/
--     notification_inbox_screen.dart): select-mode entry, selection counter,
--     select-all toggle, and the bulk mark-read / mark-unread / delete
--     actions.
--   - Chat archive (lib/screens/chats/chats_screen.dart, ChatArchiveService):
--     the Archived view entry, header and empty states plus the bulk
--     archive/unarchive actions and their result snackbars.
--
-- The chats screen reuses the inbox's selection keys (inboxSelectedCount,
-- inboxSelectAll, inboxDeselectAll) so both surfaces stay word-for-word
-- identical.
--
-- Total: 16 keys x 3 locales (en, es, he) = 48 translation entries.
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: ENGLISH TRANSLATIONS (en)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('en', 'inboxSelect', 'Select notifications', NOW(), NOW()),
('en', 'inboxSelectedCount', '{count} selected', NOW(), NOW()),
('en', 'inboxSelectAll', 'Select all', NOW(), NOW()),
('en', 'inboxDeselectAll', 'Deselect all', NOW(), NOW()),
('en', 'inboxMarkRead', 'Mark read', NOW(), NOW()),
('en', 'inboxMarkUnread', 'Mark unread', NOW(), NOW()),
('en', 'inboxDeleteSelected', 'Delete selected', NOW(), NOW()),
('en', 'inboxDeleteSelectedConfirm', 'Delete {count} selected notifications? This cannot be undone.', NOW(), NOW()),
('en', 'chatsArchive', 'Archive', NOW(), NOW()),
('en', 'chatsUnarchive', 'Unarchive', NOW(), NOW()),
('en', 'chatsArchived', 'Archived', NOW(), NOW()),
('en', 'chatsArchivedEmptyTitle', 'No archived chats', NOW(), NOW()),
('en', 'chatsArchivedEmptyMessage', 'Chats you archive will appear here. Archived chats still receive notifications — you can bring them back anytime.', NOW(), NOW()),
('en', 'chatsArchivedCount', '{count} chats archived', NOW(), NOW()),
('en', 'chatsUnarchivedCount', '{count} chats unarchived', NOW(), NOW()),
('en', 'chatsArchivedHint', 'Archived chats stay out of your list but keep receiving notifications', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 2: SPANISH TRANSLATIONS (es)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('es', 'inboxSelect', 'Seleccionar notificaciones', NOW(), NOW()),
('es', 'inboxSelectedCount', '{count} seleccionadas', NOW(), NOW()),
('es', 'inboxSelectAll', 'Seleccionar todo', NOW(), NOW()),
('es', 'inboxDeselectAll', 'Deseleccionar todo', NOW(), NOW()),
('es', 'inboxMarkRead', 'Marcar leídas', NOW(), NOW()),
('es', 'inboxMarkUnread', 'Marcar no leídas', NOW(), NOW()),
('es', 'inboxDeleteSelected', 'Eliminar seleccionadas', NOW(), NOW()),
('es', 'inboxDeleteSelectedConfirm', '¿Eliminar {count} notificaciones seleccionadas? Esta acción no se puede deshacer.', NOW(), NOW()),
('es', 'chatsArchive', 'Archivar', NOW(), NOW()),
('es', 'chatsUnarchive', 'Desarchivar', NOW(), NOW()),
('es', 'chatsArchived', 'Archivados', NOW(), NOW()),
('es', 'chatsArchivedEmptyTitle', 'No hay chats archivados', NOW(), NOW()),
('es', 'chatsArchivedEmptyMessage', 'Los chats que archives aparecerán aquí. Los chats archivados siguen recibiendo notificaciones — puedes recuperarlos cuando quieras.', NOW(), NOW()),
('es', 'chatsArchivedCount', '{count} chats archivados', NOW(), NOW()),
('es', 'chatsUnarchivedCount', '{count} chats desarchivados', NOW(), NOW()),
('es', 'chatsArchivedHint', 'Los chats archivados salen de tu lista pero siguen recibiendo notificaciones', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 3: HEBREW TRANSLATIONS (he)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('he', 'inboxSelect', 'בחירת התראות', NOW(), NOW()),
('he', 'inboxSelectedCount', '{count} נבחרו', NOW(), NOW()),
('he', 'inboxSelectAll', 'בחירת הכל', NOW(), NOW()),
('he', 'inboxDeselectAll', 'ביטול בחירה', NOW(), NOW()),
('he', 'inboxMarkRead', 'סימון כנקרא', NOW(), NOW()),
('he', 'inboxMarkUnread', 'סימון כלא נקרא', NOW(), NOW()),
('he', 'inboxDeleteSelected', 'מחיקת הנבחרות', NOW(), NOW()),
('he', 'inboxDeleteSelectedConfirm', 'למחוק {count} התראות נבחרות? לא ניתן לשחזר פעולה זו.', NOW(), NOW()),
('he', 'chatsArchive', 'העברה לארכיון', NOW(), NOW()),
('he', 'chatsUnarchive', 'החזרה מהארכיון', NOW(), NOW()),
('he', 'chatsArchived', 'ארכיון', NOW(), NOW()),
('he', 'chatsArchivedEmptyTitle', 'אין צ׳אטים בארכיון', NOW(), NOW()),
('he', 'chatsArchivedEmptyMessage', 'צ׳אטים שתעביר לארכיון יופיעו כאן. צ׳אטים בארכיון עדיין מקבלים התראות — תוכל להחזיר אותם בכל עת.', NOW(), NOW()),
('he', 'chatsArchivedCount', '{count} צ׳אטים הועברו לארכיון', NOW(), NOW()),
('he', 'chatsUnarchivedCount', '{count} צ׳אטים הוחזרו מהארכיון', NOW(), NOW()),
('he', 'chatsArchivedHint', 'צ׳אטים בארכיון יוצאים מהרשימה אך ממשיכים לקבל התראות', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
