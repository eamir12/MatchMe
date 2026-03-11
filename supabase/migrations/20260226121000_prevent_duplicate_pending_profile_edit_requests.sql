BEGIN;

CREATE OR REPLACE FUNCTION public.prevent_duplicate_pending_profile_edit_requests()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  f text;
BEGIN
  IF NEW.status <> 'pending' THEN
    RETURN NEW;
  END IF;

  FOREACH f IN ARRAY COALESCE(NEW.requested_fields, '{}'::text[])
  LOOP
    f := NULLIF(trim(f), '');
    IF f IS NULL THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.profile_edit_requests r
      WHERE r.user_id = NEW.user_id
        AND r.status = 'pending'
        AND r.requested_fields @> ARRAY[f]
    ) THEN
      RAISE EXCEPTION 'profile_edit_request_already_pending';
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_duplicate_pending_profile_edit_requests ON public.profile_edit_requests;
CREATE TRIGGER trg_prevent_duplicate_pending_profile_edit_requests
BEFORE INSERT ON public.profile_edit_requests
FOR EACH ROW
EXECUTE FUNCTION public.prevent_duplicate_pending_profile_edit_requests();

COMMIT;
