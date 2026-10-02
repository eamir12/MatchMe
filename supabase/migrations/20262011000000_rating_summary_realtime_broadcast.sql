-- Migration: Realtime rating-summary updates via Broadcast
--
-- Problem: `match_ratings` RLS only allows the rater or the ratee to SELECT a
-- row. So when C rates B, user A (matched with B, but neither rater nor
-- ratee) can NOT receive `postgres_changes` for that row — A's home screen
-- keeps showing B's stale stars.
--
-- Fix: server-side Broadcast trigger that emits only the affected `ratee_id`
-- (no individual q1..q5 scores, so no private data leaks) on the public
-- `rating_updates` / `rating_updated` topic. Clients subscribed to that
-- broadcast re-fetch the aggregate via the SECURITY DEFINER
-- `get_user_rating_summary` RPC (allowed for any authenticated user).
-- The rater's client also sends the same broadcast best-effort in
-- `MatchRatingService.submitRating`, so updates propagate even before this
-- migration is deployed; the trigger covers offline-rater + backfill cases.
--
-- Also adds `match_ratings` to the `supabase_realtime` publication so the
-- rater/ratee themselves still get direct postgres_changes (RLS permits).

BEGIN;

-- 1) Allow authenticated to receive match_ratings realtime rows that pass RLS
-- (rater or ratee). No policy change: third-party viewers still get nothing
-- via postgres_changes; they rely on the broadcast below.
GRANT SELECT ON TABLE public.match_ratings TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'match_ratings'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.match_ratings;
    RAISE NOTICE 'public.match_ratings added to supabase_realtime publication';
  ELSE
    RAISE NOTICE 'public.match_ratings already in supabase_realtime publication';
  END IF;
END $$;

-- 2) Broadcast trigger: on every new rating, notify all listeners that this
-- ratee's aggregate changed. Payload is intentionally minimal.
CREATE OR REPLACE FUNCTION public.notify_rating_summary_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    -- Topic 'rating_updates', event 'rating_updated', public (not private).
    -- Guarded: if the realtime extension/schema is absent (local dev), skip
    -- silently instead of failing the rating insert.
    IF to_regproc('realtime.send(text,text,jsonb,boolean)') IS NOT NULL THEN
      PERFORM realtime.send(
        'rating_updates',
        'rating_updated',
        jsonb_build_object('ratee_id', NEW.ratee_id),
        false
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Never fail the rating write because broadcast failed.
    RAISE WARNING 'notify_rating_summary_changed broadcast failed: %', SQLERRM;
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_notify_rating_summary_changed ON public.match_ratings;
CREATE TRIGGER trigger_notify_rating_summary_changed
AFTER INSERT ON public.match_ratings
FOR EACH ROW
EXECUTE FUNCTION public.notify_rating_summary_changed();

COMMIT;
