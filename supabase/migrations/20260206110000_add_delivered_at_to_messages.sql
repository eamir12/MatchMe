-- Migration: Add delivered_at column to track message delivery status
-- Purpose: Track when a message was delivered to recipient's device (distinct from read_at)
-- Status indicator: 1 check (sent), 2 grey checks (delivered), 2 blue checks (read)

BEGIN;

-- Add delivered_at column to chat_messages if not already present
ALTER TABLE IF EXISTS public.chat_messages
ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMPTZ;

-- Create index on delivered_at for efficient queries
CREATE INDEX IF NOT EXISTS idx_chat_messages_delivered_at ON public.chat_messages(delivered_at);

-- Add function to mark a message as delivered
CREATE OR REPLACE FUNCTION public.mark_message_delivered(p_message_id uuid)
RETURNS VOID AS $$
BEGIN
  UPDATE public.chat_messages
  SET delivered_at = CASE 
    WHEN delivered_at IS NULL THEN NOW()
    ELSE delivered_at
  END
  WHERE id = p_message_id
    AND delivered_at IS NULL; -- Only update if not already marked as delivered
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION public.mark_message_delivered(uuid) TO authenticated;

COMMIT;
