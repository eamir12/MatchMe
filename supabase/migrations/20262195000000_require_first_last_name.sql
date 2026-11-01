-- One-word names are not allowed anywhere in the product. The display format
-- is "First L.", which needs a first and a last name; a single word has no
-- legitimate rendering and used to surface as "Someone" to other members.
--
-- This migration:
--   1. adds public._has_first_and_last_name(), the shared validity test;
--   2. repairs legacy rows: email addresses and placeholder words are cleared
--      from users.name, and every account whose name cannot be shown as
--      "First L." is taken out of the completed set so it cannot appear in
--      presence counts or matching until the wizard collects the full name;
--   3. adds a users trigger that rejects any write of a one-word name;
--   4. stops the auth signup trigger from seeding names from the email
--      address (or a single-word provider name);
--   5. lets a completed profile correct an invalid name once without an
--      admin unlock — the lock trigger keeps protecting valid names;
--   6. adds the copy shown when the name fields are incomplete.

BEGIN;

-- At least two whitespace-separated words after stripping the bidi and
-- zero-width marks the app may have added around names.
CREATE OR REPLACE FUNCTION public._has_first_and_last_name(p_name text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN v.cleaned = '' THEN false
    ELSE cardinality(regexp_split_to_array(v.cleaned, '\s+')) >= 2
  END
  FROM (
    SELECT btrim(
      regexp_replace(
        COALESCE(p_name, ''),
        '[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]',
        '',
        'g'
      )
    ) AS cleaned
  ) AS v;
$$;

-- Legacy repair. Email addresses and placeholder words were seeded by the
-- old signup trigger; they are never names.
DO $$
DECLARE
  v_cleared integer;
  v_flagged integer;
BEGIN
  UPDATE public.users
  SET name = ''
  WHERE name IS NOT NULL
    AND (
      position('@' IN name) > 0
      OR btrim(name) IN ('Unnamed', 'MatchMe')
    );
  GET DIAGNOSTICS v_cleared = ROW_COUNT;

  -- An account without a displayable full name must not be treated as a
  -- completed profile: this removes it from presence counts and matching
  -- until the app routes the member to Basics and collects the full name.
  UPDATE public.users
  SET is_profile_complete = false
  WHERE COALESCE(is_profile_complete, false)
    AND NOT public._has_first_and_last_name(name);
  GET DIAGNOSTICS v_flagged = ROW_COUNT;

  RAISE NOTICE
    'require_first_last_name: cleared % placeholder names, returned % accounts to the wizard',
    v_cleared, v_flagged;
END
$$;

CREATE OR REPLACE FUNCTION public.enforce_full_name_on_users()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_name text;
BEGIN
  v_name := regexp_replace(btrim(COALESCE(NEW.name, '')), '\s+', ' ', 'g');
  NEW.name := v_name;

  IF TG_OP = 'INSERT' THEN
    -- A brand-new auth account has no name yet; the profile wizard collects
    -- the first and last name before the profile can be completed. Any other
    -- name written at insert time must already be a full name.
    IF v_name = '' OR public._has_first_and_last_name(v_name) THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'user_name_must_include_first_and_last_name';
  END IF;

  -- Only a changed name is rejected, so a legacy one-word row can still
  -- receive updates for unrelated fields while its owner is being routed to
  -- the name-completion step.
  IF NEW.name IS DISTINCT FROM OLD.name
     AND NOT public._has_first_and_last_name(v_name) THEN
    RAISE EXCEPTION 'user_name_must_include_first_and_last_name';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_require_full_name ON public.users;
CREATE TRIGGER trg_users_require_full_name
BEFORE INSERT OR UPDATE OF name ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.enforce_full_name_on_users();

-- New accounts: a provider name is kept only when it already has both parts;
-- the email address is never used as a name. The wizard collects the rest.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_meta_name text;
BEGIN
  v_meta_name := btrim(
    COALESCE(
      NEW.raw_user_meta_data ->> 'name',
      NEW.raw_user_meta_data ->> 'full_name',
      ''
    )
  );
  INSERT INTO public.users (id, name, email)
  VALUES (
    NEW.id,
    CASE
      WHEN public._has_first_and_last_name(v_meta_name)
        THEN regexp_replace(v_meta_name, '\s+', ' ', 'g')
      ELSE ''
    END,
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

-- Latest definition (20260331120000) plus one exception: a completed profile
-- whose stored name is not a full name may be corrected without an admin
-- unlock. The new value is still validated by trg_users_require_full_name,
-- and once the name is valid the one-time lock applies again.
CREATE OR REPLACE FUNCTION public.enforce_basic_details_one_time_edit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_role text;
  v_is_admin boolean;
  v_used_fields text[] := '{}'::text[];
  v_old_fields text[] := '{}'::text[];
BEGIN
  v_role := auth.role();

  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF v_role = 'service_role' THEN
    RETURN NEW;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF COALESCE(v_is_admin, false) THEN
    RETURN NEW;
  END IF;

  v_old_fields := COALESCE(OLD.editable_profile_fields, '{}'::text[]);

  -- While a profile is still incomplete, basic details remain editable.
  -- When the user completes their profile, strip any temporary unlocks for
  -- these fields so future edits require an admin-approved unlock.
  IF COALESCE(NEW.is_profile_complete, false)
     AND NOT COALESCE(OLD.is_profile_complete, false) THEN
    SELECT COALESCE(array_agg(f), '{}'::text[])
    INTO NEW.editable_profile_fields
    FROM unnest(v_old_fields) AS t(f)
    WHERE f <> ALL (ARRAY['name', 'gender', 'date_of_birth']);

    IF COALESCE(array_length(NEW.editable_profile_fields, 1), 0) = 0 THEN
      NEW.editable_profile_fields := NULL;
    END IF;
  END IF;

  IF NOT COALESCE(OLD.is_profile_complete, false) THEN
    RETURN NEW;
  END IF;

  IF NEW.name IS DISTINCT FROM OLD.name THEN
    IF NOT ('name' = ANY(v_old_fields))
       AND public._has_first_and_last_name(OLD.name) THEN
      RAISE EXCEPTION 'basic_details_update_not_allowed';
    END IF;
    v_used_fields := v_used_fields || ARRAY['name'];
  END IF;

  IF NEW.gender IS DISTINCT FROM OLD.gender THEN
    IF NOT ('gender' = ANY(v_old_fields)) THEN
      RAISE EXCEPTION 'basic_details_update_not_allowed';
    END IF;
    v_used_fields := v_used_fields || ARRAY['gender'];
  END IF;

  IF NEW.date_of_birth IS DISTINCT FROM OLD.date_of_birth THEN
    IF NOT ('date_of_birth' = ANY(v_old_fields)) THEN
      RAISE EXCEPTION 'basic_details_update_not_allowed';
    END IF;
    v_used_fields := v_used_fields || ARRAY['date_of_birth'];
  END IF;

  IF COALESCE(array_length(v_used_fields, 1), 0) > 0 THEN
    SELECT COALESCE(array_agg(f), '{}'::text[])
    INTO NEW.editable_profile_fields
    FROM unnest(v_old_fields) AS t(f)
    WHERE NOT (f = ANY(v_used_fields));

    IF COALESCE(array_length(NEW.editable_profile_fields, 1), 0) = 0 THEN
      NEW.editable_profile_fields := NULL;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_basic_details_one_time_edit ON public.users;
CREATE TRIGGER trg_enforce_basic_details_one_time_edit
BEFORE UPDATE ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.enforce_basic_details_one_time_edit();

INSERT INTO public.translations (locale, key, value) VALUES
('en', 'profileEditFullNameRequired', 'Enter both your first and last name.'),
('es', 'profileEditFullNameRequired', 'Ingresa tu nombre y apellido.'),
('he', 'profileEditFullNameRequired', 'יש להזין שם פרטי ושם משפחה.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
