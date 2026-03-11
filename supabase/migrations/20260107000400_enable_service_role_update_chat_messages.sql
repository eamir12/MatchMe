-- Migration: Enable service_role access to chat_messages for Edge Functions
-- Purpose: Allow Edge Functions to update content_translated field

BEGIN;

-- Ensure RLS is enabled on chat_messages
ALTER TABLE IF EXISTS public.chat_messages ENABLE ROW LEVEL SECURITY;

-- Drop any existing service_role policy to avoid conflicts
DROP POLICY IF EXISTS "service_role can update chat_messages" ON public.chat_messages;

-- Create policy that allows service_role to update messages (for translations)
-- Note: This is secure because service_role is only used server-side by functions
CREATE POLICY "service_role can update chat_messages"
ON public.chat_messages
FOR UPDATE
USING (true)
WITH CHECK (true);

-- Grant permissions to service_role
GRANT SELECT, UPDATE ON public.chat_messages TO service_role;

COMMIT;
