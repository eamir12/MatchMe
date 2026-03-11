BEGIN;

CREATE OR REPLACE FUNCTION public.cleanup_profile_edit_attachments_on_decision()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage
AS $$
DECLARE
  v_paths text[];
BEGIN
  IF TG_OP <> 'UPDATE' THEN
    RETURN NEW;
  END IF;

  IF COALESCE(OLD.status, '') <> 'pending' OR NEW.status NOT IN ('approved', 'rejected') THEN
    RETURN NEW;
  END IF;

  IF NEW.attachments IS NULL OR jsonb_typeof(NEW.attachments) <> 'array' THEN
    RETURN NEW;
  END IF;

  BEGIN
    SELECT array_agg(DISTINCT cleaned_path)
    INTO v_paths
    FROM (
      SELECT
        NULLIF(
          regexp_replace(
            regexp_replace(
              regexp_replace(
                regexp_replace(
                  COALESCE(a.value->>'url', ''),
                  '^https?://[^/]+/storage/v1/object/(sign|public)/profile-edit-attachments/',
                  ''
                ),
                '^profile-edit-attachments/',
                ''
              ),
              '^/+',
              ''
            ),
            '\\?.*$',
            ''
          ),
          ''
        ) AS cleaned_path,
        NULLIF(btrim(COALESCE(a.value->>'bucket', '')), '') AS bucket_name
      FROM jsonb_array_elements(NEW.attachments) AS a(value)
    ) s
    WHERE cleaned_path IS NOT NULL
      AND (bucket_name IS NULL OR bucket_name = 'profile-edit-attachments');

    IF v_paths IS NOT NULL AND COALESCE(array_length(v_paths, 1), 0) > 0 THEN
      DELETE FROM storage.objects
      WHERE bucket_id = 'profile-edit-attachments'
        AND name = ANY(v_paths);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_profile_edit_attachments_on_decision() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cleanup_profile_edit_attachments_on_decision() TO authenticated;

DROP TRIGGER IF EXISTS trg_cleanup_profile_edit_attachments_on_decision ON public.profile_edit_requests;
CREATE TRIGGER trg_cleanup_profile_edit_attachments_on_decision
AFTER UPDATE OF status ON public.profile_edit_requests
FOR EACH ROW
EXECUTE FUNCTION public.cleanup_profile_edit_attachments_on_decision();

COMMIT;
