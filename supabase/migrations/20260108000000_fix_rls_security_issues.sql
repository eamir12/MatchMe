-- Migration: Fix RLS security issues
-- Enable RLS on tables that are missing it and add appropriate policies

BEGIN;

-- Enable RLS on message_reactions table
-- This table stores user reactions to messages, should only be accessible by authenticated users
ALTER TABLE IF EXISTS public.message_reactions ENABLE ROW LEVEL SECURITY;

-- Allow authenticated users to manage their own reactions
CREATE POLICY "Users can manage own reactions" ON public.message_reactions
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- Allow service role full access (for background operations)
CREATE POLICY "Service role can access all reactions" ON public.message_reactions
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Enable RLS on user_recent_matches table
-- This table stores recent match activity for users
ALTER TABLE IF EXISTS public.user_recent_matches ENABLE ROW LEVEL SECURITY;

-- Allow users to read their own recent matches
CREATE POLICY "Users can read own recent matches" ON public.user_recent_matches
  USING (auth.uid() = user_id);

-- Allow service role full access (for background operations)
CREATE POLICY "Service role can access all recent matches" ON public.user_recent_matches
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Enable RLS on translation_trigger_logs table
-- This table is for debugging/logging, should be restricted
ALTER TABLE IF EXISTS public.translation_trigger_logs ENABLE ROW LEVEL SECURITY;

-- Only service role can access translation logs (for debugging)
CREATE POLICY "Only service role can access translation logs" ON public.translation_trigger_logs
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Note: chats table intentionally has RLS disabled (see 20260107000200_disable_rls_on_chats.sql)
-- Note: app_config table already has RLS enabled with service_role policy

COMMIT;

