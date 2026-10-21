-- Migration: Enable realtime on the tables the app subscribes to but that
-- were never added to the `supabase_realtime` publication.
--
-- Realtime only delivers `postgres_changes` for tables that are members of the
-- publication. These four tables are subscribed to by the app, but no
-- migration in this repo added them, so their realtime subscriptions were
-- silently dead - the client received a `subscribed` acknowledgement and then
-- never got a single event:
--
--   public.user_invisibility_rules
--     lib/providers/invisibility_rules_provider.dart
--     The invisibility rules a user configured on one device were only ever
--     picked up by the periodic pull, never pushed.
--
--   public.matches
--     lib/providers/home_providers.dart,
--     lib/providers/match_notification_provider.dart
--     New/removed matches were not pushed to the other devices.
--
--   public.app_profile_options
--     lib/providers/new_options_provider.dart
--     Profile option lists were not pushed live.
--
--   public.chat_messages
--     lib/providers/home_providers.dart, lib/providers/chat_provider.dart
--     Already present on hosted Supabase (added by hand), so this is a no-op
--     there - it just makes the repo self-describing so a fresh database gets
--     the same publication membership.
--
-- The publication is owned by `supabase_admin` on hosted Supabase, and the
-- role used for migrations often cannot alter it. This migration is
-- therefore fail-safe: it swallows every error (including "already member of
-- publication") instead of rolling back. If the ALTER does not take effect,
-- enable the table by hand in
-- Dashboard -> Database -> Replication -> Tables and realtime starts
-- delivering immediately.
BEGIN;

DO $$
DECLARE
  target text;
BEGIN
  FOREACH target IN ARRAY ARRAY[
    'public.user_invisibility_rules',
    'public.matches',
    'public.app_profile_options',
    'public.chat_messages'
  ]
  LOOP
    BEGIN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE %s', target);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Could not add % to supabase_realtime publication: %', target, SQLERRM;
    END;
  END LOOP;
END;
$$;

COMMIT;
