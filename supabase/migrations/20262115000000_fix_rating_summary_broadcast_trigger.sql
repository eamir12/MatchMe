-- Migration: Fix the rating-summary realtime broadcast trigger.
--
-- `20262011000000_rating_summary_realtime_broadcast.sql` redefined
-- public.notify_rating_summary_changed() but got the realtime.send() contract
-- wrong, so the server-side broadcast never fired:
--
--   * The guard checked `to_regproc('realtime.send(text,text,jsonb,boolean)')`,
--     but the real signature is `realtime.send(jsonb, text, text, boolean)`.
--     to_regproc() therefore returned NULL and the PERFORM was skipped on every
--     write.
--   * Even the call passed its arguments in the wrong order
--     ('rating_updates', 'rating_updated', jsonb, false).
--
-- The rater's device still sent a best-effort client broadcast, but any rating
-- written while that client was offline (or whose broadcast was dropped) never
-- reached matched viewers, so their match-box stars stayed stale.
--
-- This restores the correct (payload, event, topic, private) order with a
-- fallback for the legacy signature, and collapses the two overlapping
-- triggers down to a single INSERT/UPDATE/DELETE trigger.

BEGIN;

CREATE OR REPLACE FUNCTION public.notify_rating_summary_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ratee uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_ratee := OLD.ratee_id;
  ELSE
    v_ratee := NEW.ratee_id;
  END IF;

  IF v_ratee IS NULL THEN
    RETURN NULL;
  END IF;

  BEGIN
    -- Current realtime.send signature: (payload, event, topic, private).
    -- Public (private = false) to match the app's `client.channel('rating_updates')`
    -- subscription; payload carries only the ratee id (no scores).
    PERFORM realtime.send(
      jsonb_build_object('ratee_id', v_ratee),
      'rating_updated',
      'rating_updates',
      false
    );
  EXCEPTION
    WHEN undefined_function THEN
      -- Legacy realtime.send signature: (topic, event, payload, max_chunk_size).
      BEGIN
        PERFORM realtime.send(
          'rating_updates',
          'rating_updated',
          jsonb_build_object('ratee_id', v_ratee),
          1000000
        );
      EXCEPTION WHEN OTHERS THEN
        NULL; -- best-effort only
      END;
    WHEN OTHERS THEN
      -- Never fail the rating write because the broadcast failed.
      NULL;
  END;

  RETURN NULL;
END;
$$;

-- Collapse the overlapping triggers (one from 20260915, one from 20262011)
-- into a single canonical trigger so an INSERT broadcasts exactly once.
DROP TRIGGER IF EXISTS trigger_match_ratings_broadcast ON public.match_ratings;
DROP TRIGGER IF EXISTS trigger_notify_rating_summary_changed ON public.match_ratings;
CREATE TRIGGER trigger_match_ratings_broadcast
AFTER INSERT OR UPDATE OR DELETE ON public.match_ratings
FOR EACH ROW
EXECUTE FUNCTION public.notify_rating_summary_changed();

COMMIT;
