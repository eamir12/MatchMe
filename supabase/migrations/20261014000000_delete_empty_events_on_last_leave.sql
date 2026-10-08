-- Migration: Auto-delete events when the last attendee leaves
--
-- leaveEvent's client comment has always claimed "the trigger will
-- automatically delete the event if no attendees remain" — no such trigger
-- existed. A zero-attendee zombie event blocks re-imports (the save path
-- either links the user back to a dead event or hits the unique constraint
-- on a row RLS may not even show them) and is invisible dead weight.
--
-- 1. Trigger: after an event_attendees row is deleted, if nobody attends
--    the event anymore, drop its event-type matches and delete the event.
--    SECURITY DEFINER so RLS on events/matches can't block the leave.
-- 2. One-time cleanup of zombie events created before this trigger.
BEGIN;

CREATE OR REPLACE FUNCTION public.delete_event_when_last_attendee_leaves()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.event_attendees a
    WHERE a.event_id = OLD.event_id
  ) THEN
    -- Defensive: event matches reference the event; drop them first so a
    -- foreign key can't block the deletion.
    DELETE FROM public.matches m
    WHERE m.event_id = OLD.event_id
      AND m.match_type = 'event';

    BEGIN
      DELETE FROM public.events e WHERE e.id = OLD.event_id;
    EXCEPTION WHEN OTHERS THEN
      -- Never block the leave itself; leaving a zombie behind is the
      -- pre-trigger status quo and can be cleaned up later.
      NULL;
    END;
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_delete_event_when_empty ON public.event_attendees;
CREATE TRIGGER trg_delete_event_when_empty
AFTER DELETE ON public.event_attendees
FOR EACH ROW
EXECUTE FUNCTION public.delete_event_when_last_attendee_leaves();

-- One-time cleanup: remove existing events that have no attendees at all
-- (zombies from before this trigger). Every event is created with its
-- creator as an attendee, so zero-attendee rows are dead by definition.
DO $$
BEGIN
  DELETE FROM public.matches m
  WHERE m.match_type = 'event'
    AND m.event_id IN (
      SELECT e.id FROM public.events e
      WHERE NOT EXISTS (
        SELECT 1 FROM public.event_attendees a WHERE a.event_id = e.id
      )
    );

  DELETE FROM public.events e
  WHERE NOT EXISTS (
    SELECT 1 FROM public.event_attendees a WHERE a.event_id = e.id
  );
EXCEPTION WHEN OTHERS THEN
  -- Cleanup is best-effort; don't fail the migration on unexpected FKs.
  NULL;
END;
$$;

COMMIT;
