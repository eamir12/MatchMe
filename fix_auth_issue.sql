-- ============================================================
-- FIX: Database error granting user after migration
-- ============================================================

-- STEP 1: Drop EVERYTHING related to auth user creation hooks
-- These are recreated in the next step
DROP FUNCTION IF EXISTS public.handle_new_user() CASCADE;
DROP FUNCTION IF EXISTS public.create_personal_profile() CASCADE;
DROP FUNCTION IF EXISTS public.grant_user_role() CASCADE;
DROP FUNCTION IF EXISTS public.create_public_profile() CASCADE;

-- Drop only user-defined triggers on auth.users (skip RI constraint triggers)
DO $$
DECLARE
  trg RECORD;
BEGIN
  FOR trg IN
    SELECT tgname FROM pg_trigger
    WHERE tgrelid = 'auth.users'::regclass
      AND NOT tgisinternal
  LOOP
    EXECUTE 'DROP TRIGGER IF EXISTS ' || quote_ident(trg.tgname) || ' ON auth.users;';
  END LOOP;
END;
$$;

-- STEP 2: Recreate handle_new_user with ONLY the columns that STILL EXIST on public.users
-- Columns remaining after STEP 8 of the migration:
--   id, created_at, name, email, date_of_birth, gender, preferred_language,
--   subscription_tier, subscription_expires_at, is_profile_complete,
--   editable_profile_fields, is_verified, verification_status,
--   verification_submitted_at, verification_reviewed_at, user_visibility_setting,
--   system_visibility_status, is_admin, referral_code, credits,
--   match_radius_default, gps_interval_default, smart_gps_throttling_enabled,
--   shared_event_matching_enabled, shared_movement_matching_enabled
-- The email column is always populated so public.users.email reflects the
-- auth email regardless of how the user was created (password signup, OAuth,
-- admin-created, etc.). auth.users.email is the source of truth; the
-- raw_user_meta_data.email fallback covers providers that only stamp the email
-- into metadata.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.users (id, name, email)
  VALUES (
    NEW.id,
    COALESCE(
      NEW.raw_user_meta_data ->> 'name',
      NEW.email,
      ''
    ),
    COALESCE(
      NEW.email,
      NEW.raw_user_meta_data ->> 'email'
    )
  );
  RETURN NEW;
END;
$$;

-- STEP 3: Recreate the trigger
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- STEP 4: Grant necessary permissions
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
GRANT ALL ON TABLE public.users TO supabase_auth_admin;
GRANT ALL ON TABLE public.user_profiles TO supabase_auth_admin;

-- STEP 5: Verify the fix
SELECT 'handle_new_user function' AS check_item,
       prosrc AS source
FROM pg_proc WHERE proname = 'handle_new_user';
