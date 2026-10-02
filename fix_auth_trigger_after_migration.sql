-- Run this SQL after the migration to fix auth trigger issues.
-- The "Database error granting user" error occurs when GoTrue's
-- on_auth_user_created trigger references columns dropped by the migration.

-- STEP 1: Check the current trigger function
SELECT proname, prosrc
FROM pg_proc
WHERE proname = 'handle_new_user';

-- STEP 2: Recreate the trigger function WITHOUT the dropped columns.
-- The columns dropped from public.users in STEP 8 were:
--   bio, photos, approved_primary_photos, height, occupation, education,
--   zodiac_sign, lifestyle, family, religion, languages_known,
--   instagram_url, linkedin_url, facebook_url, active_modes,
--   personal_interests, business_interests, gender_preferences,
--   age_preferences, lifestyle_filters, family_filters, religion_filters,
--   height_preferences, strict_gender_age_enforcement
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
    COALESCE(NEW.raw_user_meta_data ->> 'name', NEW.email, ''),
    COALESCE(NEW.email, NEW.raw_user_meta_data ->> 'email')
  );
  RETURN NEW;
END;
$$;

-- STEP 3: Ensure the trigger exists
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();
