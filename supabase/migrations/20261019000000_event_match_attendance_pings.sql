-- Migration: Instant "your match just joined your event" signals
--
-- The matched-attendees display ("1 of your matches attending") could only
-- update via the 60s poll: the user's realtime subscription on
-- event_attendees is filtered to their OWN rows (widening it would leak
-- other attendees' private notes through whole-row payloads), so the
-- change that matters — a match joining an event I attend — produced no
-- push at all.
--
-- Fix: a minimal signal table. When a user joins an event, a trigger
-- writes one ping row per match of theirs who already attends that event;
-- when an event match is created, both users get pinged about each other.
-- Clients subscribe to their own pings (RLS: target_user_id = auth.uid())
-- and refresh instantly. Ping rows carry no private payload.
BEGIN;

CREATE TABLE IF NOT EXISTS public.event_match_attendance_pings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL,
  attendee_user_id uuid NOT NULL,
  target_user_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT event_match_attendance_pings_unique
    UNIQUE (event_id, attendee_user_id, target_user_id)
);

ALTER TABLE public.event_match_attendance_pings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users read their own attendance pings"
  ON public.event_match_attendance_pings;

CREATE POLICY "users read their own attendance pings"
  ON public.event_match_attendance_pings
  FOR SELECT
  TO authenticated
  USING (target_user_id = auth.uid());

-- No INSERT/UPDATE/DELETE policies: clients never write here; the
-- SECURITY DEFINER triggers below do.

GRANT SELECT ON public.event_match_attendance_pings TO authenticated;

-- 1) When a user joins an event, ping each of their matches who already
--    attends it. Covers pre-existing matches of any type.
CREATE OR REPLACE FUNCTION public.notify_matched_attendance()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  other_id uuid;
BEGIN
  FOR other_id IN
    SELECT CASE WHEN m.user1_id = NEW.user_id THEN m.user2_id ELSE m.user1_id END
    FROM public.matches m
    WHERE m.user1_id = NEW.user_id OR m.user2_id = NEW.user_id
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.event_attendees ea
      WHERE ea.event_id = NEW.event_id AND ea.user_id = other_id
    ) THEN
      INSERT INTO public.event_match_attendance_pings
        (event_id, attendee_user_id, target_user_id)
      VALUES (NEW.event_id, NEW.user_id, other_id)
      ON CONFLICT (event_id, attendee_user_id, target_user_id) DO NOTHING;
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_matched_attendance ON public.event_attendees;
CREATE TRIGGER trg_notify_matched_attendance
AFTER INSERT ON public.event_attendees
FOR EACH ROW
EXECUTE FUNCTION public.notify_matched_attendance();

-- 2) When an event match is created, both users learn the other attends
--    (co-attendance is implied by event matching). Covers the case where
--    the match itself is the new information (both orders of trigger
--    firing relative to #1 are safe — pings are idempotent).
CREATE OR REPLACE FUNCTION public.notify_event_match_attendance()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.event_id IS NULL THEN
    RETURN NEW;
  END IF;
  INSERT INTO public.event_match_attendance_pings
    (event_id, attendee_user_id, target_user_id)
  VALUES (NEW.event_id, NEW.user2_id, NEW.user1_id)
  ON CONFLICT (event_id, attendee_user_id, target_user_id) DO NOTHING;
  INSERT INTO public.event_match_attendance_pings
    (event_id, attendee_user_id, target_user_id)
  VALUES (NEW.event_id, NEW.user1_id, NEW.user2_id)
  ON CONFLICT (event_id, attendee_user_id, target_user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_event_match_attendance ON public.matches;
CREATE TRIGGER trg_notify_event_match_attendance
AFTER INSERT ON public.matches
FOR EACH ROW
EXECUTE FUNCTION public.notify_event_match_attendance();

-- 3) Realtime delivery (fail-safe, same caveat as before: if the SQL role
--    can't alter the publication, enable the table in Dashboard ->
--    Database -> Replication).
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.event_match_attendance_pings;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
END;
$$;

COMMIT;
