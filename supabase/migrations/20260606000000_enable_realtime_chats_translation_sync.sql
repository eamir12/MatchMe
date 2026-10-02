-- Migration: Enable realtime push on public.chats for cross-device translation sync
-- Purpose: Allow the message translation toggle (translation_enabled /
-- translation_language columns on public.chats) to propagate to all of a
-- user's logged-in devices in real time. Without this, the toggle changes
-- silently on the server and other devices only learn about it via the
-- 60s periodic chat pull or when the chat list is rebuilt.
--
-- Background:
--   The chats table already has columns translation_enabled and
-- translation_language (added in 20260101150000_add_translation_columns_to_chats.sql)
-- and the client writes to them via the set_chat_translation RPC. The missing
-- piece is the realtime push: the table was never added to the
-- supabase_realtime publication, and the client subscription in
-- home_providers.dart only handles DELETE events.
--
-- Notes:
--   * GRANT SELECT is required on top of the publication: Supabase Realtime
--     only delivers events for rows the caller is permitted to read, so the
--     existing RLS policies on public.chats (see
--     20260108000001_enable_rls_on_chats_with_policies.sql) already limit
--     delivery to the two participants of each match.
--   * ALTER PUBLICATION ADD TABLE is idempotent in effect because we guard
--     it with the same pg_publication_tables check used in
--     20260506242000_ensure_user_activity_realtime_permissions.sql.

BEGIN;

-- Ensure authenticated users can SELECT from public.chats (RLS still applies).
-- The table already had owner-only access; realtime needs an explicit grant.
GRANT SELECT ON TABLE public.chats TO authenticated;
GRANT SELECT ON TABLE public.chats TO anon;

-- Add public.chats to the supabase_realtime publication (idempotent).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND tablename = 'chats'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.chats;
        RAISE NOTICE 'public.chats added to supabase_realtime publication';
    ELSE
        RAISE NOTICE 'public.chats already in supabase_realtime publication';
    END IF;
END $$;

COMMIT;
