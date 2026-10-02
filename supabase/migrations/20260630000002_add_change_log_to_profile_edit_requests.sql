BEGIN;

-- Add change_log column to profile_edit_requests
ALTER TABLE public.profile_edit_requests
  ADD COLUMN IF NOT EXISTS change_log jsonb NOT NULL DEFAULT '[]'::jsonb;

-- Trigger function to log field changes on the users table
CREATE OR REPLACE FUNCTION public.log_profile_field_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_field text;
  v_old_val text;
  v_new_val text;
  v_request_id uuid;
BEGIN
  IF OLD.editable_profile_fields IS DISTINCT FROM NEW.editable_profile_fields THEN
    FOR v_field IN
      SELECT unnest(COALESCE(OLD.editable_profile_fields, '{}'::text[]))
      EXCEPT
      SELECT unnest(COALESCE(NEW.editable_profile_fields, '{}'::text[]))
    LOOP
      -- Only log if the actual field value changed (user-initiated, not admin rejection)
      IF v_field = 'name' AND NEW.name IS NOT DISTINCT FROM OLD.name THEN
        CONTINUE;
      END IF;
      IF v_field = 'date_of_birth' AND NEW.date_of_birth IS NOT DISTINCT FROM OLD.date_of_birth THEN
        CONTINUE;
      END IF;
      IF v_field = 'gender' AND NEW.gender IS NOT DISTINCT FROM OLD.gender THEN
        CONTINUE;
      END IF;

      v_old_val := CASE v_field
        WHEN 'name' THEN OLD.name
        WHEN 'date_of_birth' THEN OLD.date_of_birth::text
        WHEN 'gender' THEN OLD.gender
        ELSE NULL
      END;

      v_new_val := CASE v_field
        WHEN 'name' THEN NEW.name
        WHEN 'date_of_birth' THEN NEW.date_of_birth::text
        WHEN 'gender' THEN NEW.gender
        ELSE NULL
      END;

      SELECT r.id INTO v_request_id
      FROM public.profile_edit_requests r
      WHERE r.user_id = NEW.id
        AND r.status = 'approved'
        AND r.requested_fields @> ARRAY[v_field]
      ORDER BY r.created_at DESC
      LIMIT 1;

      IF v_request_id IS NOT NULL THEN
        UPDATE public.profile_edit_requests
        SET change_log = COALESCE(change_log, '[]'::jsonb) || jsonb_build_object(
          'field', v_field,
          'old_value', v_old_val,
          'new_value', v_new_val,
          'changed_at', now()
        )
        WHERE id = v_request_id;
      END IF;
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_log_profile_field_change ON public.users;
CREATE TRIGGER trg_log_profile_field_change
  AFTER UPDATE OF editable_profile_fields
  ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.log_profile_field_change();

COMMIT;
