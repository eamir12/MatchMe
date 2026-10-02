-- Migration: Broadcast rating_changes in realtime from the DB.
--
-- When a row in public.match_ratings is written by ANY path (the app RPC,
-- the Supabase dashboard SQL editor, admin scripts, future server logic),
-- emit the same public broadcast the app already listens to:
--   topic: 'rating_updates'  event: 'rating_updated'  payload: {ratee_id: ...}
--
-- Receivers re-fetch the aggregate via the SECURITY DEFINER
-- get_user_rating_summary RPC, so the payload only carries the ratee id —
-- no individual scores — and no private rating data leaks.
--
-- The payload is sent as a PUBLIC broadcast (private flag = false) because
-- the app subscribes with the default public channel config
-- (`client.channel('rating_updates')`, no `private: true`).
-- Public/private must match on both sides or the message is dropped.

BEGIN;

CREATE OR REPLACE FUNCTION public.notify_rating_summary_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
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
    PERFORM realtime.send(
      jsonb_build_object('ratee_id', v_ratee),
      'rating_updated',
      'rating_updates',
      false -- public: matches the app's public channel
    );
  EXCEPTION
    WHEN undefined_function THEN
      -- Older realtime extension signature:
      -- (topic, event, payload, max_chunk_size_bytes).
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

DROP TRIGGER IF EXISTS trigger_match_ratings_broadcast ON public.match_ratings;
CREATE TRIGGER trigger_match_ratings_broadcast
AFTER INSERT OR UPDATE OR DELETE ON public.match_ratings
FOR EACH ROW
EXECUTE FUNCTION public.notify_rating_summary_changed();

COMMIT;
