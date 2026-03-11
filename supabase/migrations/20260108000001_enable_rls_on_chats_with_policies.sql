-- Migration: Enable RLS on chats table with proper security policies
-- Re-enables RLS that was previously disabled, with policies for authenticated users and service role

BEGIN;

-- Enable RLS on chats table
ALTER TABLE IF EXISTS public.chats ENABLE ROW LEVEL SECURITY;

-- Drop any existing policies to start fresh
DROP POLICY IF EXISTS "service_role_read_all" ON public.chats;
DROP POLICY IF EXISTS "service_role_update_all" ON public.chats;
DROP POLICY IF EXISTS "users_read_own_chats" ON public.chats;
DROP POLICY IF EXISTS "users_update_own_chats" ON public.chats;
DROP POLICY IF EXISTS "users_insert_own_chats" ON public.chats;

-- Policy 1: Service role has full access to all chats (for Edge Functions and background operations)
CREATE POLICY "service_role_full_access_chats"
ON public.chats
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- Policy 3: Authenticated users can read chats where they are a participant
CREATE POLICY "users_read_own_chats"
ON public.chats
FOR SELECT
USING (
  auth.uid() = user_id OR
  auth.uid() = other_user_id
);

-- Policy 4: Authenticated users can update chats where they are a participant
CREATE POLICY "users_update_own_chats"
ON public.chats
FOR UPDATE
USING (
  auth.uid() = user_id OR
  auth.uid() = other_user_id
)
WITH CHECK (
  auth.uid() = user_id OR
  auth.uid() = other_user_id
);

-- Policy 5: Authenticated users can insert chats where they are a participant
CREATE POLICY "users_insert_own_chats"
ON public.chats
FOR INSERT
WITH CHECK (
  auth.uid() = user_id OR
  auth.uid() = other_user_id
);

COMMIT;
