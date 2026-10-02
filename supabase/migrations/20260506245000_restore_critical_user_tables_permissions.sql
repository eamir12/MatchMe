-- Restore SELECT permission on critical user-facing tables
-- These tables were revoked in security hardening but are needed for app functionality
-- RLS policies ensure users can only access data they're allowed to see

-- Match Tables (users need to see their matches)
GRANT SELECT ON TABLE public.matches TO authenticated;
GRANT SELECT ON TABLE public.matches TO anon;

-- User Profiles (users need to see other profiles)
GRANT SELECT ON TABLE public.user_profiles TO authenticated;
GRANT SELECT ON TABLE public.user_profiles TO anon;

-- User Locations (for nearby features)
GRANT SELECT ON TABLE public.user_locations TO authenticated;
GRANT SELECT ON TABLE public.user_locations TO anon;

-- Users table (needed for basic user info)
GRANT SELECT ON TABLE public.users TO authenticated;
GRANT SELECT ON TABLE public.users TO anon;

-- Event Tables
GRANT SELECT ON TABLE public.events TO authenticated;
GRANT SELECT ON TABLE public.events TO anon;

GRANT SELECT ON TABLE public.event_attendees TO authenticated;
GRANT SELECT ON TABLE public.event_attendees TO anon;

-- Message Reactions
GRANT SELECT ON TABLE public.message_reactions TO authenticated;
GRANT SELECT ON TABLE public.message_reactions TO anon;

-- Verify the permissions
SELECT
    table_name,
    privilege_type,
    grantee
FROM information_schema.table_privileges
WHERE table_schema = 'public'
    AND table_name IN ('matches', 'user_profiles', 'user_locations', 'users', 'events', 'event_attendees', 'message_reactions')
    AND privilege_type = 'SELECT'
ORDER BY table_name, grantee;