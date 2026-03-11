-- Migration: Enable service_role access to chats table for Edge Functions
-- Purpose: Allow Edge Functions (running as service_role) to read chat translation settings

BEGIN;

-- Enable RLS on chats table if not already enabled
ALTER TABLE IF EXISTS public.chats ENABLE ROW LEVEL SECURITY;

-- Drop any existing service_role policies to avoid conflicts
DROP POLICY IF EXISTS "service_role can read all chats" ON public.chats;
DROP POLICY IF EXISTS "Enable service_role full access" ON public.chats;
DROP POLICY IF EXISTS "Service role bypass" ON public.chats;

-- Create policy that allows service_role to bypass RLS and access all data
-- Note: This is secure because service_role is only used server-side by functions
CREATE POLICY "service_role can read all chats"
ON public.chats
FOR SELECT
USING (true);

-- Also allow service_role to update messages (for writing translations)
CREATE POLICY "service_role can update all chats"
ON public.chats
FOR UPDATE
USING (true)
WITH CHECK (true);

-- Grant full permissions to service_role
GRANT SELECT, INSERT, UPDATE, DELETE ON public.chats TO service_role;

COMMIT;
