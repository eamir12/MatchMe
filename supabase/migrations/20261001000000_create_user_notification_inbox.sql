-- Migration: Persistent per-user notification inbox ("notification email box").
--
-- Purpose:
--   Until now every notification the system sent (admin broadcasts, match
--   expiry warnings, new matches, match extensions, birthday automations,
--   visibility warnings, chat message pushes) was transient: an OS tray card
--   and/or an in-memory Riverpod banner. Once dismissed it was gone, and only
--   admin broadcasts were queryable afterwards (via admin_broadcast_deliveries).
--
--   This migration adds public.user_notifications — the single durable record
--   of every notification addressed to a user — plus a capture trigger on
--   notification_queue so everything that flows through the outbound FCM queue
--   lands in the inbox automatically. Chat/new-match pushes (sent directly by
--   the push-message edge function, bypassing the queue) are inserted by that
--   function. Location-share alerts (client-local realtime events) are
--   inserted by the client, which is why authenticated INSERT is allowed.
--
-- Design notes:
--   - Soft delete (deleted_at) so "delete" in the UI is undoable-safe and the
--     client can keep an optimistic list; a cleanup job can hard-delete later.
--   - read_at is nullable; NULL means unread. Unread badge = count where
--     read_at IS NULL AND deleted_at IS NULL.
--   - Dedupe: chat pushes can legitimately fire more than once per message
--     (client trigger + DB webhook + translate-proxy re-send), so a unique
--     partial index on (user_id, data->>'message_id') lets writers use
--     ON CONFLICT DO NOTHING for chat rows.
--   - The queue capture trigger is SECURITY DEFINER: notification_queue has no
--     RLS and is written by service_role / SECURITY DEFINER RPCs, so the
--     trigger's insert must not depend on the invoking role's privileges.
--   - Type strings mirror the `data.type` values already used across the
--     system (admin_broadcast, match, new_match, match_expiry, pinned_expiry,
--     match_extended, chat_message, birthday, visibility_warning, ...), so the
--     client can map them to icons/labels without a server change.

BEGIN;

CREATE TABLE IF NOT EXISTS public.user_notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    type TEXT NOT NULL DEFAULT 'general',
    title TEXT NOT NULL,
    body TEXT NOT NULL DEFAULT '',
    data JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_at TIMESTAMPTZ,
    deleted_at TIMESTAMPTZ
);

-- Inbox listing: newest first, excluding deleted.
CREATE INDEX IF NOT EXISTS idx_user_notifications_inbox
  ON public.user_notifications (user_id, created_at DESC)
  WHERE deleted_at IS NULL;

-- Unread badge count.
CREATE INDEX IF NOT EXISTS idx_user_notifications_unread
  ON public.user_notifications (user_id)
  WHERE deleted_at IS NULL AND read_at IS NULL;

-- Chat push dedupe: one inbox row per (user, message).
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_notifications_message_dedupe
  ON public.user_notifications (user_id, (data->>'message_id'))
  WHERE data->>'message_id' IS NOT NULL AND data->>'message_id' <> '';

ALTER TABLE public.user_notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own inbox notifications" ON public.user_notifications;
DROP POLICY IF EXISTS "Users can update own inbox notifications" ON public.user_notifications;
DROP POLICY IF EXISTS "Users can delete own inbox notifications" ON public.user_notifications;
DROP POLICY IF EXISTS "Users can insert own inbox notifications" ON public.user_notifications;

CREATE POLICY "Users can view own inbox notifications" ON public.user_notifications
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can update own inbox notifications" ON public.user_notifications
  FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own inbox notifications" ON public.user_notifications
  FOR DELETE USING (auth.uid() = user_id);

-- The client inserts rows for notification kinds that never touch the server
-- (e.g. live-location-share alerts raised from realtime signals). Server-side
-- writers use service_role, which bypasses RLS, so no policy is needed there.
CREATE POLICY "Users can insert own inbox notifications" ON public.user_notifications
  FOR INSERT WITH CHECK (auth.uid() = user_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_notifications TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_notifications TO service_role;

-- Dedupe guard for chat pushes: the same message can reach push-message via
-- multiple invocation paths (client trigger, DB webhook, translate-proxy
-- re-send). Drop exact duplicates here so writers need no ON CONFLICT target
-- against the expression index. The partial unique index below stays as a
-- concurrency backstop.
CREATE OR REPLACE FUNCTION public.trg_user_notifications_dedupe()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(NEW.data->>'message_id', '') <> '' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.data->>'message_id' = NEW.data->>'message_id'
    ) THEN
      RETURN NULL;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_notifications_dedupe ON public.user_notifications;
CREATE TRIGGER trg_user_notifications_dedupe
  BEFORE INSERT ON public.user_notifications
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_user_notifications_dedupe();

-- 2) Capture trigger: everything enqueued into notification_queue (match
--    expiry warnings, new-match enqueues from DB triggers, admin broadcasts,
--    birthday automations, visibility warnings, match extensions, ...)
--    automatically lands in the inbox at enqueue time.
CREATE OR REPLACE FUNCTION public.trg_notification_queue_to_inbox()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.user_id IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.user_notifications (user_id, type, title, body, data)
  VALUES (
    NEW.user_id,
    COALESCE(NULLIF(btrim(COALESCE(NEW.data->>'type', '')), ''), 'general'),
    NEW.title,
    COALESCE(NEW.body, ''),
    COALESCE(NEW.data, '{}'::jsonb)
  )
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notification_queue_to_inbox ON public.notification_queue;
CREATE TRIGGER trg_notification_queue_to_inbox
  AFTER INSERT ON public.notification_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_notification_queue_to_inbox();

-- 3) Realtime: the client subscribes to inbox INSERTs for the unread badge
--    and live list updates. Postgres changes only fire for tables in the
--    supabase_realtime publication (idempotent add).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'user_notifications'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.user_notifications;
    RAISE NOTICE 'public.user_notifications added to supabase_realtime publication';
  ELSE
    RAISE NOTICE 'public.user_notifications already in supabase_realtime publication';
  END IF;
END;
$$;

COMMIT;
