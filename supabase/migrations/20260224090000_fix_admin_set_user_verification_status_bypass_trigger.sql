BEGIN;

CREATE OR REPLACE FUNCTION public.admin_set_user_verification_status(
  p_user_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_status text;
  v_verification_photo_path text;
  v_delete_object_path text;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_status := NULLIF(trim(p_status), '');
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'p_status is required';
  END IF;

  IF v_status NOT IN ('unverified', 'analyzing', 'pending', 'approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid status';
  END IF;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  SELECT u.verification_photo_path
  INTO v_verification_photo_path
  FROM public.users u
  WHERE u.id = p_user_id;

  UPDATE public.users u
  SET
    verification_status = v_status,
    is_verified = (v_status = 'approved'),
    verification_reviewed_at = CASE WHEN v_status IN ('approved', 'rejected') THEN now() ELSE NULL END,
    verification_reviewer_id = CASE WHEN v_status IN ('approved', 'rejected') THEN auth.uid() ELSE NULL END,
    verification_photo_path = CASE WHEN v_status = 'approved' THEN NULL ELSE u.verification_photo_path END
  WHERE u.id = p_user_id;

  IF v_status = 'approved' THEN
    v_delete_object_path := NULLIF(btrim(COALESCE(v_verification_photo_path, '')), '');
    IF v_delete_object_path IS NULL THEN
      v_delete_object_path := p_user_id::text || '/verification.jpg';
    END IF;

    v_delete_object_path := ltrim(v_delete_object_path, '/');
    IF v_delete_object_path LIKE 'verification-photos/%' THEN
      v_delete_object_path := substr(v_delete_object_path, length('verification-photos/') + 1);
    END IF;

    DELETE FROM storage.objects o
    WHERE o.bucket_id = 'verification-photos'
      AND o.name = v_delete_object_path;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_user_verification_status(uuid, text) TO authenticated;

COMMIT;
