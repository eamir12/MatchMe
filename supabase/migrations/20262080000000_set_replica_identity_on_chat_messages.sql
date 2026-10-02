-- Migration: Set REPLICA IDENTITY FULL on public.chat_messages
-- Purpose: Make payload.oldRecord in UPDATE realtime events contain the full
-- previous row instead of just the primary-key columns. Required for the
-- sender's single → double checkmark path (delivered_at / read_at) and the
-- translation-payload fast path in lib/providers/chat_provider.dart to use
-- old-vs-new comparison instead of falling through to a full re-select +
-- full Hive rewrite + full re-decrypt on every UPDATE.
--
-- Background:
--   Verified on prod: SELECT relreplident FROM pg_class WHERE
--   relname = 'chat_messages' returns 'd' (DEFAULT), and chat_messages IS in
--   the supabase_realtime publication. So realtime UPDATEs fire, but oldRecord
--   is `{id}` only, which made isStatusOnlyChange() / isEncryptedContentChange()
--   always return false.
--
--   The client now ALSO compares newRecord against the local Hive row
--   (isStatusOnlyVsCached / isEncryptedContentOnlyVsCached), so this migration
--   is an optimization, not a hard requirement. With FULL, the cheap
--   old-vs-new path works again and one local Hive read per UPDATE is saved.
--
--   Same trade-off as 20260606000001 (chats → FULL): slightly larger WAL per
--   UPDATE, negligible at chat write volumes.
--
-- Rollback: ALTER TABLE public.chat_messages REPLICA IDENTITY DEFAULT;

BEGIN;

ALTER TABLE public.chat_messages REPLICA IDENTITY FULL;

COMMIT;
