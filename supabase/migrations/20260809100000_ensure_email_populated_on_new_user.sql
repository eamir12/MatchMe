-- Ensure public.users.email is always populated for NEW users, regardless of
-- how the auth user is created (password signup, OAuth, admin-created, etc.).
--
-- Every auth user creation (email/password via secure-sign-up, OAuth providers,
-- passkeys, admin API) inserts into auth.users and fires the
-- on_auth_user_created trigger. The previous trigger body only wrote id + name,
-- so public.users.email stayed NULL for every new user.
--
-- auth.users.email is the source of truth. The raw_user_meta_data->>'email'
-- fallback covers OAuth providers that stamp the email into the raw metadata.
-- No backfill is performed here (existing rows stay untouched).

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

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();