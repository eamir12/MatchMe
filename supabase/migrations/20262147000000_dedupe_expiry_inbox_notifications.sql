-- Migration: Deduplicate expiry notifications in the persistent inbox.
--
-- Problem:
--   handleMatchExpiryWarnings / handlePinnedExpiryWarnings (supabase/functions/
--   cron-jobs) wrote every warning to public.user_notifications directly AND
--   enqueued one notification_queue row per registered device token. The capture
--   trigger trg_notification_queue_to_inbox copies every queue row into the
--   inbox, so a single warning produced 1 + <active device sessions> identical
--   inbox rows (3 copies for a user with 2 devices).
--
--   The inbox dedupe trigger only covered message_id and match/new_match, and
--   the only unique indexes on user_notifications covered those same two cases,
--   so the "ON CONFLICT DO NOTHING" inside the capture trigger was a no-op for
--   expiry rows.
--
-- Fix:
--   1) Delete the duplicates that already exist (keep one copy per warning).
--   2) Add partial unique indexes for match_expiry / pinned_expiry so the
--      capture trigger's ON CONFLICT DO NOTHING actually dedupes.
--   3) Extend trg_user_notifications_dedupe to the expiry types so writers
--      that do not use ON CONFLICT DO NOTHING are covered as well.
--
-- Note: the index expressions below are repeated verbatim in the dedupe
-- trigger's EXISTS predicates. Postgres can only use an index for a lookup
-- when the query expression matches the index expression exactly, so the two
-- must be kept in sync.

BEGIN;

-- 1) Remove existing duplicates -------------------------------------------
-- Keep the copy the user already interacted with (read), otherwise the newest.
WITH keyed AS (
  SELECT
    id,
    ROW_NUMBER() OVER (
      PARTITION BY
        user_id,
        type,
        COALESCE(data->>'match_id', data->>'matchId', ''),
        COALESCE(data->>'threshold_seconds', ''),
        COALESCE(data->>'expiry_at', '')
      ORDER BY (read_at IS NOT NULL) DESC, created_at DESC, id DESC
    ) AS rn
  FROM public.user_notifications
  WHERE type IN ('match_expiry', 'pinned_expiry')
)
DELETE FROM public.user_notifications un
USING keyed k
WHERE un.id = k.id
  AND k.rn > 1;

-- 2) Unique indexes -------------------------------------------------------
-- One inbox row per (user, match, threshold, expiry window). The indexes are
-- deliberately NOT restricted to deleted_at IS NULL: a warning is a one-shot
-- event, so deleting it must not let the next cron tick recreate it.
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_notifications_match_expiry_dedupe
  ON public.user_notifications (
    user_id,
    (COALESCE(data->>'match_id', data->>'matchId', '')),
    (COALESCE(data->>'threshold_seconds', '')),
    (COALESCE(data->>'expiry_at', ''))
  )
  WHERE type = 'match_expiry';

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_notifications_pinned_expiry_dedupe
  ON public.user_notifications (
    user_id,
    (COALESCE(data->>'threshold_seconds', '')),
    (COALESCE(data->>'expiry_at', ''))
  )
  WHERE type = 'pinned_expiry';

-- 3) Dedupe trigger --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_user_notifications_dedupe()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_message_id text;
  v_match_id text;
  v_threshold text;
  v_expiry_at text;
BEGIN
  v_message_id := COALESCE(NEW.data->>'message_id', '');
  v_match_id := COALESCE(NEW.data->>'match_id', NEW.data->>'matchId', '');

  IF v_message_id <> '' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.data->>'message_id' = v_message_id
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  IF v_match_id <> '' AND NEW.type IN ('match', 'new_match') THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.type IN ('match', 'new_match')
        AND COALESCE(un.data->>'match_id', un.data->>'matchId', '') = v_match_id
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  -- Expiry warnings: the cron job writes the row directly and the queue
  -- capture trigger writes one row per device token. Keep the first copy.
  v_threshold := COALESCE(NEW.data->>'threshold_seconds', '');
  v_expiry_at := COALESCE(NEW.data->>'expiry_at', '');

  IF NEW.type = 'match_expiry' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.type = 'match_expiry'
        AND COALESCE(un.data->>'match_id', un.data->>'matchId', '') = v_match_id
        AND COALESCE(un.data->>'threshold_seconds', '') = v_threshold
        AND COALESCE(un.data->>'expiry_at', '') = v_expiry_at
    ) THEN
      RETURN NULL;
    END IF;
  ELSIF NEW.type = 'pinned_expiry' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.type = 'pinned_expiry'
        AND COALESCE(un.data->>'threshold_seconds', '') = v_threshold
        AND COALESCE(un.data->>'expiry_at', '') = v_expiry_at
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

COMMIT;
