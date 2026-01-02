-- Migration: message reactions
-- Purpose: add message_reactions table, set_message_reaction RPC, and maintain chat_messages.reaction_summary

BEGIN;

-- Add reaction_summary column to chat_messages if not present
ALTER TABLE IF EXISTS public.chat_messages
  ADD COLUMN IF NOT EXISTS reaction_summary jsonb DEFAULT '{}'::jsonb;

-- Create message_reactions table
CREATE TABLE IF NOT EXISTS public.message_reactions (
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  reaction text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_message_reactions_message_id ON public.message_reactions (message_id);
CREATE INDEX IF NOT EXISTS idx_message_reactions_user_id ON public.message_reactions (user_id);

-- Function to recompute reaction summary for a given message
CREATE OR REPLACE FUNCTION public.recompute_reaction_summary(p_message_id uuid) RETURNS jsonb AS $$
DECLARE
  summary jsonb;
BEGIN
  SELECT jsonb_object_agg(reaction, cnt) INTO summary
  FROM (
    SELECT reaction, count(*)::int AS cnt
    FROM public.message_reactions
    WHERE message_id = p_message_id
    GROUP BY reaction
  ) t;

  IF summary IS NULL THEN
    summary := '{}'::jsonb;
  END IF;

  UPDATE public.chat_messages SET reaction_summary = summary WHERE id = p_message_id;
  RETURN summary;
END;
$$ LANGUAGE plpgsql VOLATILE; -- Must be VOLATILE because it performs UPDATEs


-- Trigger function to update summary on changes
CREATE OR REPLACE FUNCTION public.handle_message_reactions_change() RETURNS trigger AS $$
DECLARE
  affected_id uuid;
BEGIN
  IF (TG_OP = 'INSERT') THEN
    affected_id := NEW.message_id;
  ELSIF (TG_OP = 'UPDATE') THEN
    affected_id := NEW.message_id;
    -- In case message_id changed (unlikely), update old one too
    IF OLD.message_id IS DISTINCT FROM NEW.message_id THEN
      PERFORM public.recompute_reaction_summary(OLD.message_id);
    END IF;
  ELSIF (TG_OP = 'DELETE') THEN
    affected_id := OLD.message_id;
  END IF;

  PERFORM public.recompute_reaction_summary(affected_id);
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Attach triggers
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='message_reactions') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_message_reactions_change') THEN
      CREATE TRIGGER trg_message_reactions_change
      AFTER INSERT OR UPDATE OR DELETE ON public.message_reactions
      FOR EACH ROW EXECUTE FUNCTION public.handle_message_reactions_change();
    END IF;
  END IF;
END$$;

-- RPC to set or clear a reaction for the current user (auth.uid())
DROP FUNCTION IF EXISTS public.set_message_reaction(uuid, text);
CREATE OR REPLACE FUNCTION public.set_message_reaction(p_message_id uuid, p_reaction text) RETURNS jsonb AS $$
DECLARE
  my_user uuid := auth.uid();
  new_summary jsonb;
BEGIN
  IF my_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF p_reaction IS NULL THEN
    DELETE FROM public.message_reactions WHERE message_id = p_message_id AND user_id = my_user;
  ELSE
    INSERT INTO public.message_reactions (message_id, user_id, reaction)
    VALUES (p_message_id, my_user, p_reaction)
    ON CONFLICT (message_id, user_id) DO UPDATE SET reaction = EXCLUDED.reaction, created_at = now();
  END IF;

  SELECT public.recompute_reaction_summary(p_message_id) INTO new_summary;
  RETURN new_summary;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute rights on RPC
GRANT EXECUTE ON FUNCTION public.set_message_reaction(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_message_reaction(uuid, text) TO anon;

COMMIT;
