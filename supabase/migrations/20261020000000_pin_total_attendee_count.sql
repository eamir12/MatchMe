-- Migration: "N attending" reflects ALL MatchMe users attending the event
--
-- The events card's attendee count comes from count_event_attendees. The
-- repo's known definition already counts every event_attendees row, but
-- the base schema dump is empty (the function predates migrations) and the
-- deployed body can't be verified — so pin it explicitly: the count is the
-- total number of attendees regardless of their match relationship to the
-- caller. It's how the user gauges how many potential matches exist at the
-- event. A bare count leaks nothing (no user lists, ever).
BEGIN;

CREATE OR REPLACE FUNCTION public.count_event_attendees(event_id_param uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    attendee_count integer;
BEGIN
    SELECT COUNT(*)
    INTO attendee_count
    FROM public.event_attendees
    WHERE event_id = event_id_param;
    RETURN COALESCE(attendee_count, 0);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.count_event_attendees(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.count_event_attendees(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.count_event_attendees(uuid) TO authenticated;

COMMIT;
