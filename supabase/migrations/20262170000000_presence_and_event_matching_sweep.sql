-- Presence + event matching cleanup.
--
-- 1) Retire the standalone 30 s "detect-offline-users" job. It wrote
--    presence_events rows that nothing in the app reads (clients consume
--    user_activity via Realtime), and its 10–20 s activity window missed
--    roughly two thirds of offline transitions at a 30 s cadence anyway.
--    Offline presence is already driven by cleanup_stale_online_users(),
--    which flips user_activity.is_online and emits the Realtime UPDATE the
--    clients subscribe to.
-- 2) Make cleanup_stale_online_users() cheap with a partial index.
-- 3) Replace the no-op perform_continuous_event_matching() stub with a
--    bounded sweep that catches events whose attendance changed without the
--    join trigger completing (trigger timeouts, deletes, historical rows).

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Unschedule the dead offline-broadcast job (guarded: cron may be absent
--    in a local reset, and the job may already be gone).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_jobid bigint;
BEGIN
  IF to_regclass('cron.job') IS NULL THEN
    RETURN;
  END IF;

  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'detect-offline-users';
  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
    RAISE NOTICE 'Unscheduled legacy cron job detect-offline-users (jobid %)', v_jobid;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2) Presence lookup index.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_user_activity_stale_online
  ON public.user_activity (last_activity)
  WHERE is_online = true;

-- ---------------------------------------------------------------------------
-- 3) Event matching bookkeeping.
-- ---------------------------------------------------------------------------
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS last_matched_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_attendee_count integer,
  ADD COLUMN IF NOT EXISTS last_match_attempt_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_events_match_sweep
  ON public.events (start_time)
  WHERE end_time IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_event_attendees_event_id
  ON public.event_attendees (event_id);

-- Existing events were matched by the join trigger as attendees arrived.
-- Record that baseline so the sweep does not re-run O(n^2) matching over the
-- whole future calendar on the first tick. Events are re-swept only when
-- their attendee count changes.
UPDATE public.events e
SET last_matched_at = COALESCE(e.last_matched_at, now()),
    last_attendee_count = (
      SELECT count(*) FROM public.event_attendees ea WHERE ea.event_id = e.id
    )
WHERE e.end_time >= now()
  AND e.last_attendee_count IS NULL;

-- The join trigger now records the sweep baseline after matching, so the
-- sweep only has real work when the trigger did not finish.
CREATE OR REPLACE FUNCTION public.trigger_perform_event_matching()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.perform_event_matching(NEW.event_id);

    UPDATE public.events e
    SET last_matched_at = now(),
        last_attendee_count = (
          SELECT count(*) FROM public.event_attendees ea WHERE ea.event_id = e.id
        )
    WHERE e.id = NEW.event_id;
  END IF;
  RETURN NEW;
END;
$$;

-- Return type changes from void to integer, so the stub must be dropped.
DROP FUNCTION IF EXISTS public.perform_continuous_event_matching();

CREATE FUNCTION public.perform_continuous_event_matching()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event record;
  v_processed integer := 0;
  v_now timestamptz := now();
BEGIN
  FOR v_event IN
    SELECT e.id
    FROM public.events e
    WHERE e.end_time >= v_now
      AND e.start_time <= v_now + interval '30 days'
      AND (
        e.last_matched_at IS NULL
        OR e.last_attendee_count IS DISTINCT FROM (
          SELECT count(*) FROM public.event_attendees ea WHERE ea.event_id = e.id
        )
      )
      AND (
        e.last_match_attempt_at IS NULL
        OR e.last_match_attempt_at < v_now - interval '15 minutes'
      )
    ORDER BY e.last_match_attempt_at NULLS FIRST, e.start_time ASC
    LIMIT 10
  LOOP
    UPDATE public.events
    SET last_match_attempt_at = v_now
    WHERE id = v_event.id;

    BEGIN
      PERFORM public.perform_event_matching(v_event.id);
    EXCEPTION WHEN OTHERS THEN
      -- One pathological event must not starve the rest of the sweep.
      RAISE WARNING 'perform_event_matching failed for event %: %', v_event.id, SQLERRM;
      CONTINUE;
    END;

    UPDATE public.events e
    SET last_matched_at = v_now,
        last_attendee_count = (
          SELECT count(*) FROM public.event_attendees ea WHERE ea.event_id = e.id
        )
    WHERE e.id = v_event.id;

    v_processed := v_processed + 1;
  END LOOP;

  RETURN v_processed;
END;
$$;

REVOKE ALL ON FUNCTION public.perform_continuous_event_matching() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.perform_continuous_event_matching() FROM anon;
REVOKE ALL ON FUNCTION public.perform_continuous_event_matching() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.perform_continuous_event_matching() TO service_role;

COMMIT;
