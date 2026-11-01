-- Migration: chats.updated_at moves on every row change
--
-- The list delta (FINDINGS 12.1) selects chats rows with updated_at > the
-- client's watermark. Message inserts, read receipts and translation toggles
-- already set updated_at, but ChatArchiveService.setArchived writes only
-- archived_at. A device that was killed therefore never sees the archive
-- until the 24 h full reconcile — proven on device 2026-11-01 (archive via
-- the app's own PATCH, relaunch, delta returned 0 chats).
--
-- A BEFORE UPDATE trigger makes updated_at the last-change time for every
-- write path, the same invariant matches has had since 20262219000000. Every
-- existing writer already sets now() in the same statement, so no timestamp
-- moves backwards; the new movement is the archive/unarchive write that
-- motivated this. Without it, unarchive is invisible by definition:
-- archived_at = NULL leaves no timestamp of its own.
--
-- Ordering note: get_user_recent_chats orders by
-- GREATEST(last_message_at, updated_at). Archiving a chat therefore counts
-- as activity, exactly as marking it read already does.
--
-- Rollback: DROP TRIGGER trg_chats_set_updated_at ON public.chats;

BEGIN;

DROP TRIGGER IF EXISTS trg_chats_set_updated_at ON public.chats;
CREATE TRIGGER trg_chats_set_updated_at
  BEFORE UPDATE ON public.chats
  FOR EACH ROW
  EXECUTE FUNCTION public.set_row_updated_at();

COMMIT;
