-- Migration: Set REPLICA IDENTITY FULL on public.chats
-- Purpose: Make payload.oldRecord in UPDATE realtime events contain the full
-- previous row instead of just the primary-key columns. Required for the
-- cross-device translation-toggle sync in home_providers.dart to see the
-- old values of translation_enabled / translation_language.
--
-- Background:
--   public.chats has a composite primary key (user_id, match_id). With the
--   default REPLICA IDENTITY, Postgres only writes the PK columns to WAL for
--   UPDATE events, so the Supabase Realtime payload.oldRecord contains
--   {user_id, match_id} only. The client's UPDATE handler compared the
--   old and new translation columns to detect changes; with the old values
--   missing, the disable-translation case (new=(false, null) vs
--   old=(false, null) by default) silently no-ops, leaving the other
--   device's toggle state stale.
--
--   REPLICA IDENTITY FULL is safe here: public.chats is a low-write table
--   (one row per user per match, updated on send/read/receive/translation-
--   toggle only), and the realtime subscription is the only consumer that
--   reads old values.
--
--   This is also why the working user-preferences realtime subscription
--   (user_preferences_provider.dart) does not depend on oldRecord — it
--   reads only newRecord, so the default REPLICA IDENTITY is sufficient.

BEGIN;

ALTER TABLE public.chats REPLICA IDENTITY FULL;

COMMIT;
