-- Migration: Fix chats table RLS policies for both service_role and authenticated users
-- Purpose: Allow both Edge Functions (service_role) and authenticated users to access chats

BEGIN;

-- Drop conflicting policies
DROP POLICY IF EXISTS "service_role can read all chats" ON public.chats;
DROP POLICY IF EXISTS "service_role can update all chats" ON public.chats;

-- Ensure RLS is enabled
ALTER TABLE IF EXISTS public.chats ENABLE ROW LEVEL SECURITY;

-- Policy 1: Service role can read all chats (for Edge Functions)
CREATE POLICY "service_role_read_all"
ON public.chats
FOR SELECT
USING (auth.role() = 'service_role');

-- Policy 2: Service role can update all chats (for translations)
CREATE POLICY "service_role_update_all"
ON public.chats
FOR UPDATE
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- Policy 3: Authenticated users can read their own chats
CREATE POLICY "users_read_own_chats"
ON public.chats
FOR SELECT
USING (auth.uid() = user_id);

-- Policy 4: Authenticated users can update their own chats
CREATE POLICY "users_update_own_chats"
ON public.chats
FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

-- Policy 5: Authenticated users can insert their own chats
CREATE POLICY "users_insert_own_chats"
ON public.chats
FOR INSERT
WITH CHECK (auth.uid() = user_id);

-- Grant permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON public.chats TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.chats TO service_role;

COMMIT;
