-- ============================================================================
-- Migration: per-row chat menu copy
-- ============================================================================
--
-- Translation keys for the ⋮ menu on each chat row
-- (lib/widgets/chat_list_item.dart, wired in chats_screen.dart):
--   - chatsSelect: enters multi-select mode with that chat pre-selected
--     (the menu's alternative entry point next to the long-press gesture).
--   - chatsArchivedOne / chatsUnarchivedOne: singular snackbars — archiving
--     a single chat reads better without the count ("Chat archived" rather
--     than "1 chats archived"); the plural chatsArchivedCount /
--     chatsUnarchivedCount keys from migration 20262081000000 still cover
--     bulk actions.
--
-- Total: 3 keys x 3 locales (en, es, he) = 9 translation entries.
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: ENGLISH TRANSLATIONS (en)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('en', 'chatsSelect', 'Select', NOW(), NOW()),
('en', 'chatsArchivedOne', 'Chat archived', NOW(), NOW()),
('en', 'chatsUnarchivedOne', 'Chat unarchived', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 2: SPANISH TRANSLATIONS (es)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('es', 'chatsSelect', 'Seleccionar', NOW(), NOW()),
('es', 'chatsArchivedOne', 'Chat archivado', NOW(), NOW()),
('es', 'chatsUnarchivedOne', 'Chat desarchivado', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 3: HEBREW TRANSLATIONS (he)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('he', 'chatsSelect', 'בחירה', NOW(), NOW()),
('he', 'chatsArchivedOne', 'הצ׳אט הועבר לארכיון', NOW(), NOW()),
('he', 'chatsUnarchivedOne', 'הצ׳אט הוחזר מהארכיון', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
