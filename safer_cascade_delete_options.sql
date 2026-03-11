-- SAFER ALTERNATIVES FOR CASCADE DELETE OF CHAT MESSAGES
-- Choose the option that matches your intended behavior

-- OPTION 1: Delete messages when MATCHES are deleted (RECOMMENDED)
-- This preserves messages until the actual match relationship is removed

-- Drop existing trigger if it exists from the previous migration
DROP TRIGGER IF EXISTS trg_delete_messages_on_chat_deletion ON public.chats;
DROP FUNCTION IF EXISTS public.handle_chat_deletion_for_messages();

-- The existing foreign key constraint already handles this:
-- chat_messages.match_id REFERENCES matches.id ON DELETE CASCADE
-- So messages are already deleted when matches are deleted.

-- OPTION 2: Delete messages when ALL users have deleted their chat views (COMPLEX)
-- This requires tracking how many users still have the chat

-- Create a function to check if any users still have this chat
CREATE OR REPLACE FUNCTION public.should_delete_match_messages(p_match_id uuid)
RETURNS boolean AS $$
BEGIN
  -- Return true if no users have this chat in their chats table
  RETURN NOT EXISTS (
    SELECT 1 FROM public.chats
    WHERE match_id = p_match_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger function that only deletes messages when no users have the chat
CREATE OR REPLACE FUNCTION public.handle_chat_deletion_check_messages() RETURNS trigger AS $$
BEGIN
  -- Check if this was the last chat entry for this match
  IF public.should_delete_match_messages(OLD.match_id) THEN
    -- No more users have this chat, safe to delete messages
    DELETE FROM public.chat_messages WHERE match_id = OLD.match_id;
  END IF;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger
DROP TRIGGER IF EXISTS trg_check_delete_messages_on_chat_deletion ON public.chats;
CREATE TRIGGER trg_check_delete_messages_on_chat_deletion
  AFTER DELETE ON public.chats
  FOR EACH ROW EXECUTE FUNCTION public.handle_chat_deletion_check_messages();

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.should_delete_match_messages(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.should_delete_match_messages(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handle_chat_deletion_check_messages() TO authenticated;

-- OPTION 3: Add a separate function to manually clean up orphaned messages
-- This can be called periodically or on-demand

CREATE OR REPLACE FUNCTION public.cleanup_orphaned_chat_messages()
RETURNS integer AS $$
DECLARE
  deleted_count integer;
BEGIN
  -- Delete messages for matches that no longer exist
  DELETE FROM public.chat_messages
  WHERE match_id NOT IN (SELECT id FROM public.matches);

  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.cleanup_orphaned_chat_messages() TO authenticated;


