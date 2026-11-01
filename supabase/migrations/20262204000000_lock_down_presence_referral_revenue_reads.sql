-- Migration: remove anonymous and unrelated reads of presence, referral and revenue data.
-- Date: 2026-10-29
--
-- Four read policies grant more than any client uses:
--
--   user_activity           "Users can view activity for real-time updates"
--                           roles = public, USING (true). With the anon key this
--                           returns every user id, last_activity and is_online
--                           (reproduced 2026-10-29). This is the directory the
--                           S1 write chain used to target users.
--   presence_events         "Allow all users to read presence events"
--                           roles = authenticated, USING (true): every signed-in
--                           account reads every user's presence stream.
--   referral_visits         "Auth users can read own visits"
--                           roles = authenticated, USING (true). The table has no
--                           user column, so "own" is not enforced: every row,
--                           including ip_address and user_agent, is readable.
--   ad_revenue_daily_stats  "Authenticated users can read ad revenue stats"
--                           roles = authenticated, USING (true): every account
--                           reads network and ad-unit revenue.
--
-- Who reads these tables:
--   user_activity           Realtime postgres_changes subscriptions for other
--                           users' online events (dashboard stats, nearby map).
--                           The counters themselves come from
--                           get_online_dashboard_stats(), which is SECURITY
--                           DEFINER and therefore independent of these policies.
--   presence_events         written by broadcast_user_online_event(); no client read.
--   referral_visits         edge functions check-referral / invite (service role).
--   ad_revenue_daily_stats  admin tooling only; no client read.
--
-- Fix:
--   * user_activity: replace the public SELECT policy with an authenticated one.
--     anon loses the user directory; signed-in Realtime is unchanged, because
--     Realtime evaluates this SELECT policy per subscriber.
--   * presence_events, referral_visits, ad_revenue_daily_stats: drop the
--     always-true read policy. Admin (is_admin_user) and service_role policies
--     stay untouched.
--
-- Blast radius: read policies only. No table, function, body or grant changes.
-- A client read that depended on a dropped policy would return zero rows; the
-- repo scan found none outside the Realtime subscriptions above.
--
-- Verification (run after applying):
--   select tablename, policyname, roles, qual
--   from pg_policies
--   where schemaname = 'public'
--     and tablename in ('user_activity','presence_events','referral_visits','ad_revenue_daily_stats')
--   order by 1, 2;
--   -- expect user_activity: "Authenticated users can view activity for
--   -- real-time updates" roles={authenticated} qual=true, plus the admin and
--   -- service_role policies; the other three keep only admin/service_role.

drop policy if exists "Users can view activity for real-time updates"
  on public.user_activity;

create policy "Authenticated users can view activity for real-time updates"
  on public.user_activity
  for select
  to authenticated
  using (true);

drop policy if exists "Allow all users to read presence events"
  on public.presence_events;

drop policy if exists "Auth users can read own visits"
  on public.referral_visits;

drop policy if exists "Authenticated users can read ad revenue stats"
  on public.ad_revenue_daily_stats;
