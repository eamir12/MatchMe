-- Migration: Enable realtime for public.user_profiles.
--
-- The match preferences (preferred gender, age range, and the lifestyle,
-- family, religion and height filters) live in
-- `user_profiles.intent_preferences` - NOT on the `users` row. The table was
-- never added to the `supabase_realtime` publication, so the client could
-- subscribe to it but the server never sent anything: a change to the
-- preferred age range made on one device never reached the other one.
--
-- The app subscribes to the signed-in user's own rows through
-- lib/services/my_user_realtime_service.dart, which now carries a
-- postgres_changes binding for this table as well.
--
-- Rollback: ALTER PUBLICATION supabase_realtime DROP TABLE public.user_profiles;
BEGIN;

DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.user_profiles;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE
      'Could not add public.user_profiles to supabase_realtime publication: %. '
      'Enable it manually in Dashboard -> Database -> Replication.',
      SQLERRM;
  END;
END;
$$;

-- Realtime only delivers a row to a subscriber that is allowed to read it.
-- Make the owner's read access on their own profile row explicit. Policies
-- are combined with OR, so this cannot narrow what is already readable.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE tablename = 'user_profiles'
      AND policyname = 'UserProfiles: owner select'
  ) THEN
    CREATE POLICY "UserProfiles: owner select" ON public.user_profiles
      FOR SELECT
      TO authenticated
      USING (auth.uid() = user_id);
  END IF;
END;
$$;

COMMIT;
