BEGIN;

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

  IF NOT COALESCE(OLD.is_profile_complete, false) THEN
    RETURN NEW;
  END IF;

  v_old_fields := COALESCE(OLD.editable_profile_fields, '{}'::text[]);

  IF NEW.name IS DISTINCT FROM OLD.name THEN
    IF NOT ('name' = ANY(v_old_fields)) THEN
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

UPDATE public.users
SET editable_profile_fields = NULL
WHERE editable_profile_fields IS NOT NULL
  AND COALESCE(array_length(editable_profile_fields, 1), 0) = 0;

COMMIT;
