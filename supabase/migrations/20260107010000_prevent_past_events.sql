-- Migration: Prevent inserting or updating events with start_time in the past
-- Purpose: Ensure new events cannot be created with a start time that is already in the past.

-- Create validation function
CREATE OR REPLACE FUNCTION public.check_event_start_not_past()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- If an event starts in the past, reject the insert/update
  IF NEW.start_time < now() THEN
    RAISE EXCEPTION 'Event start_time (% ) must not be in the past', NEW.start_time;
  END IF;
  RETURN NEW;
END;
$$;

-- Attach trigger to events table (before insert or update)
DROP TRIGGER IF EXISTS prevent_past_event_start_time ON public.events;
CREATE TRIGGER prevent_past_event_start_time
BEFORE INSERT OR UPDATE ON public.events
FOR EACH ROW
EXECUTE FUNCTION public.check_event_start_not_past();
