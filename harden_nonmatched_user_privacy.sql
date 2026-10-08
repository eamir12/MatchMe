-- ============================================================================
-- harden_nonmatched_user_privacy.sql  (MAKE SURE YOU HAVE A BACKUP / SNAPSHOT)
--
-- Purpose: close the API-level privacy holes found by
-- check_nonmatched_user_data_exposure.sql, so that non-matched users' data is
-- truly invisible, matching the app's UI model ("only anonymous counts until
-- you match").
--
-- Findings this fixes:
--   F1. get_potential_matches / get_potential_matches_by_intents are
--       SECURITY DEFINER and executable by ANYONE (incl. anon). They return
--       non-matched users' EXACT lat/lng + full profile (bio, height,
--       occupation, education, zodiac, lifestyle, family, religion,
--       interests, photos). The app no longer calls them (Dart provider
--       deleted 2026-10-07) and no DB function calls them -> DROP.
--   F2. find_nearby_users is SECURITY DEFINER, anon-executable, and returns
--       candidate profiles + exact locations. BUT it is called internally by
--       the continuous matching functions -> KEEP the function, REVOKE
--       EXECUTE from end-user roles (internal definer calls are unaffected).
--   F3. get_potential_event_matches is anon-executable and unused by the app.
--       No DB function calls it either -> REVOKE (optional DROP in comments).
--   F4. user_profiles "Users can view all profiles" (roles: public, USING
--       true) lets ANY user — even ANON with the SELECT grant — read every
--       user's full profile. -> DROP, replace with matched-pairs policy.
--   F5. users has THREE true-SELECT policies ("Users can view other users
--       profiles", "users_select_auth", "users_select_authenticated") so any
--       authenticated user can read every user's row (real name —
--       mask_full_name only applies inside functions — DOB, gender...).
--       -> DROP all three, replace with matched-pairs policy.
--   F6. users "anon_select_truly_visible" exposes visible users' rows to
--       unauthenticated visitors; no public web page needs it (user
--       confirmed 2026-10-07) -> DROP + revoke anon SELECT grants on
--       users / user_profiles / user_locations.
--
-- What stays working after this script:
--   * Own rows (own profile, settings, theme, language, visibility) — own-row
--     policies unchanged.
--   * Matched users' profiles on chat/match screens — new matched-pairs
--     policies cover exactly those reads (direct .from('users') /
--     .from('user_profiles') queries by user_id).
--   * Realtime updates for matched users' profiles (match_profile_updates
--     channel) — delivery follows the same SELECT policies.
--   * Admin app — is_admin_user() SELECT policies unchanged.
--   * Nearby map cells, world map, dashboard counts, event matched attendees
--     — all SECURITY DEFINER RPCs, unaffected by RLS.
--   * Presence realtime for other users — via the user_activity channel
--     (see section C pre-check); the users-table channel simply goes quiet
--     for non-matched users, and the dashboard's poll fallbacks remain.
--
-- ROLLBACK (if anything breaks): re-create the dropped policies with
--   USING (true) and re-grant EXECUTE:
--     grant execute on function public.find_nearby_users(uuid, double precision,
--       double precision, double precision) to anon, authenticated;
--     ... (same shape as the GRANT lines in the migration history)
-- ============================================================================

-- ============================================================================
-- SECTION A — pre-check: confirm user_activity is readable by authenticated
-- (the dashboard's realtime presence channel depends on it after section B).
-- Run this first; verify rows come back with SELECT granted to authenticated.
-- ============================================================================
select tablename, policyname, cmd, roles, qual
from pg_policies
where schemaname = 'public' and tablename = 'user_activity'
order by policyname;

-- ============================================================================
-- SECTION B — drop the dead / leaky discovery functions
-- ============================================================================

-- B1. get_potential_matches: unused by app, unused by DB functions.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    select p.oid::regprocedure AS sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('get_potential_matches', 'get_potential_matches_by_intents')
  LOOP
    raise notice 'Dropping %', r.sig;
    execute format('DROP FUNCTION %s', r.sig);
  END LOOP;
END;
$$;

-- B2. find_nearby_users: KEEP (used internally by the matching functions),
--     but no end-user role may call it directly any more. Internal calls from
--     inside SECURITY DEFINER functions run as the function owner and are
--     unaffected by these revokes.
REVOKE EXECUTE ON FUNCTION public.find_nearby_users(uuid, double precision, double precision, double precision)
  FROM anon, authenticated, PUBLIC;

-- B3. get_potential_event_matches: unused by the app. Revoke for now; if the
--     event browse feature it was built for is confirmed dead, uncomment:
-- DROP FUNCTION IF EXISTS public.get_potential_event_matches(uuid, uuid);
REVOKE EXECUTE ON FUNCTION public.get_potential_event_matches(uuid, uuid)
  FROM anon, authenticated, PUBLIC;

-- ============================================================================
-- SECTION C — table policy fixes
-- ============================================================================

-- C1. user_profiles: remove the "everyone can read everything" policy,
--     replace with matched-pairs-only. (Dropping the new policy name too
--     makes this section safe to re-run.)
DROP POLICY IF EXISTS "Users can view all profiles" ON public.user_profiles;
DROP POLICY IF EXISTS "Users can view matched users profiles" ON public.user_profiles;

CREATE POLICY "Users can view matched users profiles"
  ON public.user_profiles
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.matches m
      WHERE (m.user1_id = auth.uid() AND m.user2_id = user_profiles.user_id)
         OR (m.user1_id = user_profiles.user_id AND m.user2_id = auth.uid())
    )
  );

-- C2. users: remove the three true-SELECT policies, replace with
--     matched-pairs-only (own row + admin + anon-visible already covered by
--     their existing policies). (Dropping the new policy name too makes this
--     section safe to re-run.)
DROP POLICY IF EXISTS "Users can view other users profiles" ON public.users;
DROP POLICY IF EXISTS "users_select_auth" ON public.users;
DROP POLICY IF EXISTS "users_select_authenticated" ON public.users;
DROP POLICY IF EXISTS "Users can view matched users" ON public.users;

CREATE POLICY "Users can view matched users"
  ON public.users
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.matches m
      -- `id` MUST be qualified as users.id: unqualified, Postgres binds it
      -- to matches.id (inner scope wins) and the policy silently matches
      -- nothing, cutting off matched users' access.
      WHERE (m.user1_id = auth.uid() AND m.user2_id = users.id)
         OR (m.user1_id = users.id AND m.user2_id = auth.uid())
    )
  );

-- C3. users: remove the anon visibility policy as well (user confirmed
--     2026-10-07 that no public web page needs it), and revoke the anon
--     SELECT grants on all three user-data tables so unauthenticated
--     visitors can no longer reach them at all. RLS would already block
--     every row after the policy drops, but revoking the grants makes the
--     intent explicit and silences security-advisor warnings.
DROP POLICY IF EXISTS "anon_select_truly_visible" ON public.users;

REVOKE SELECT ON TABLE public.users FROM anon;
REVOKE SELECT ON TABLE public.user_profiles FROM anon;
REVOKE SELECT ON TABLE public.user_locations FROM anon;

-- ============================================================================
-- SECTION D — verify the end state (re-run check_nonmatched_user_data_exposure
-- sections 1-4 afterwards; expected: no true-SELECT policy on users/user_profiles
-- except own-row/matched/admin, and anon_can_execute=false on everything left)
-- ============================================================================
select tablename, policyname, cmd, roles, qual
from pg_policies
where schemaname = 'public'
  and tablename in ('users', 'user_profiles')
  and cmd = 'SELECT'
order by tablename, policyname;
