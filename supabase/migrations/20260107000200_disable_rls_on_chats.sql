-- Migration: Disable RLS on chats table
-- Purpose: Chats table is only modified by triggers and Edge Functions, not by users directly
-- Edge Functions can use service_role which bypasses RLS anyway

BEGIN;

-- Drop all policies on chats
DROP POLICY IF EXISTS "service_role_read_all" ON public.chats;
DROP POLICY IF EXISTS "service_role_update_all" ON public.chats;
DROP POLICY IF EXISTS "users_read_own_chats" ON public.chats;
DROP POLICY IF EXISTS "users_update_own_chats" ON public.chats;
DROP POLICY IF EXISTS "users_insert_own_chats" ON public.chats;

-- Disable RLS on chats table
ALTER TABLE IF EXISTS public.chats DISABLE ROW LEVEL SECURITY;

COMMIT;
