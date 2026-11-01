-- Migration: Instant (seconds-level) notification dispatch.
--
-- Until now every push waited for the once-a-minute cron-jobs dispatcher:
-- an event-driven notification (new match, location share, meetup signal,
-- profile-edit decision, admin broadcast) could sit in notification_queue for
-- up to 60 s, and a freshly created broadcast needed a tick just to be
-- fanned out plus another tick to be drained.
--
-- This migration adds a "quick tick": when a queue row that is due now lands,
-- or a broadcast enters 'scheduled' and is due, pg_net posts to the existing
-- cron-jobs function with {quick:true}. The function then runs the matching
-- work immediately and re-posts itself while due rows remain.
--
-- The once-a-minute dispatcher is unchanged and remains the safety net:
--   - it drains anything a dropped pg_net call missed;
--   - it runs the expiry scans (time-based warnings are still cadenced by
--     the minute tick, then drain instantly once enqueued);
--   - stale-claim recovery and pruning stay there (quick ticks skip them).
--
-- Dedupe/at-most-once guarantees are untouched: the quick path claims rows
-- through the same lease + status='pending' guard as the cron drain, so the
-- two can run concurrently without double-sending.
--
-- Debounce: inserts inside one transaction (broadcast fan-out loops) update
-- the state row on the first trigger and therefore post at most one request
-- per transaction; the 3 s window also coalesces rapid sequential inserts.
-- The edge function chains at most 20 times per burst (depth carried in the
-- payload), after which the minute tick picks up the remainder.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Debounce state (single row).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS private.instant_dispatch_state (
  id integer PRIMARY KEY,
  last_requested_at timestamptz,
  last_source text
);

INSERT INTO private.instant_dispatch_state (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

REVOKE ALL ON private.instant_dispatch_state FROM PUBLIC, anon, authenticated;

-- RLS with no policies: the table is only touched by the SECURITY DEFINER
-- functions below, which run as postgres (owner bypasses RLS). The private
-- schema is not exposed through PostgREST either, so this is defense-in-depth
-- plus a clean lint result. Do NOT add FORCE ROW LEVEL SECURITY: that would
-- apply RLS to the owner too and break the debounce UPDATE.
ALTER TABLE private.instant_dispatch_state ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 2) Request a quick tick.
--    Reads the same private config the pg_cron job uses, so the call carries
--    the exact URL/keys that are already proven to work.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_notification_quick_tick(
  p_source text DEFAULT 'trigger',
  p_min_interval_seconds integer DEFAULT 3,
  p_queue boolean DEFAULT true,
  p_broadcasts boolean DEFAULT false,
  p_chain integer DEFAULT 0
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg RECORD;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_min_interval_seconds > 0 THEN
    UPDATE private.instant_dispatch_state
       SET last_requested_at = v_now,
           last_source = p_source
     WHERE id = 1
       AND (last_requested_at IS NULL
            OR last_requested_at < v_now - make_interval(secs => p_min_interval_seconds));
    IF NOT FOUND THEN
      RETURN false;  -- an earlier insert already asked for this window
    END IF;
  ELSE
    UPDATE private.instant_dispatch_state
       SET last_requested_at = v_now,
           last_source = p_source
     WHERE id = 1;
  END IF;

  SELECT c.base_url, c.anon_key, c.internal_secret
    INTO v_cfg
  FROM private.cron_job_config c
  WHERE c.id = 1;

  IF v_cfg.base_url IS NULL OR COALESCE(v_cfg.internal_secret, '') = '' THEN
    RETURN false;  -- dispatcher not configured; the minute tick still runs
  END IF;

  PERFORM net.http_post(
    url := rtrim(v_cfg.base_url, '/') || '/functions/v1/cron-jobs',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || COALESCE(v_cfg.anon_key, ''),
      'x-matchme-internal', v_cfg.internal_secret
    ),
    body := jsonb_build_object(
      'quick', true,
      'queue', p_queue,
      'broadcasts', p_broadcasts,
      'chain', p_chain
    ),
    timeout_milliseconds := 30000
  );

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.request_notification_quick_tick(text, integer, boolean, boolean, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_notification_quick_tick(text, integer, boolean, boolean, integer)
  TO service_role;

COMMENT ON FUNCTION public.request_notification_quick_tick(text, integer, boolean, boolean, integer)
  IS 'Debounced pg_net request for an immediate cron-jobs quick tick. Trigger-owned and service_role (self-chaining).';

-- ---------------------------------------------------------------------------
-- 3) Queue inserts: fire a quick tick when any inserted row is due now.
--    Statement-level with a transition table so a 2000-row broadcast chunk is
--    one trigger event, not 2000. Rows inserted by the ledger dedupe BEFORE
--    trigger (RETURN NULL) never appear here, and future-dated rows wait for
--    the minute tick.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_notification_queue_quick_dispatch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM new_rows WHERE scheduled_at <= now()) THEN
    PERFORM public.request_notification_quick_tick('queue_insert', 3, true, false, 0);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_notification_queue_quick_dispatch ON public.notification_queue;
CREATE TRIGGER trg_notification_queue_quick_dispatch
  AFTER INSERT ON public.notification_queue
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.trg_notification_queue_quick_dispatch();

-- ---------------------------------------------------------------------------
-- 4) Broadcasts: entering 'scheduled' while due dispatches immediately.
--    Only the transition INTO 'scheduled' fires (creation, or draft -> send);
--    send_admin_broadcast's own status rewrites ('sending'/'sent') do not,
--    otherwise every chunk would re-trigger the dispatcher.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_admin_broadcast_quick_dispatch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'scheduled'
     AND NEW.scheduled_at IS NOT NULL
     AND NEW.scheduled_at <= now()
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'scheduled') THEN
    PERFORM public.request_notification_quick_tick('broadcast_scheduled', 3, true, true, 0);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_admin_broadcast_quick_dispatch ON public.admin_broadcasts;
CREATE TRIGGER trg_admin_broadcast_quick_dispatch
  AFTER INSERT OR UPDATE OF status, scheduled_at ON public.admin_broadcasts
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_admin_broadcast_quick_dispatch();

NOTIFY pgrst, 'reload schema';
COMMIT;
