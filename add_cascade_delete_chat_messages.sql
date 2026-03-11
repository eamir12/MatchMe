-- Migration to automatically delete chat messages when chats are deleted
-- WARNING: This will delete ALL messages for a match when ANY user deletes their chat view
-- This may not be the intended behavior. Consider if you want to delete messages
-- when matches are deleted instead.

-- Create trigger function to delete messages when chats are deleted
CREATE OR REPLACE FUNCTION public.handle_chat_deletion_for_messages() RETURNS trigger AS $$
BEGIN
  -- Delete all messages for this match when a chat entry is deleted
  -- Note: This will affect all users, not just the one deleting their chat view
  DELETE FROM public.chat_messages WHERE match_id = OLD.match_id;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger on chats table
DROP TRIGGER IF EXISTS trg_delete_messages_on_chat_deletion ON public.chats;
CREATE TRIGGER trg_delete_messages_on_chat_deletion
  AFTER DELETE ON public.chats
  FOR EACH ROW EXECUTE FUNCTION public.handle_chat_deletion_for_messages();

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION public.handle_chat_deletion_for_messages() TO authenticated;
GRANT EXECUTE ON FUNCTION public.handle_chat_deletion_for_messages() TO anon;


