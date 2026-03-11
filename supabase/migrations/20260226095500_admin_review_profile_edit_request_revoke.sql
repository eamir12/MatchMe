DROP FUNCTION IF EXISTS public.admin_review_profile_edit_request(uuid, text, text);
CREATE OR REPLACE FUNCTION public.admin_review_profile_edit_request(
  p_request_id uuid,
  p_decision text,
  p_reviewer_note text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_decision text;
  v_req record;
  v_user_fields_type text;
  v_user_fields_udt text;
  v_cur_fields text[];
  v_req_fields text[];
  v_new_fields text[];
  v_keep_fields text[];
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

  v_decision := NULLIF(trim(p_decision), '');
  IF v_decision IS NULL THEN
    RAISE EXCEPTION 'p_decision is required';
  END IF;

  IF v_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid decision';
  END IF;

  SELECT r.* INTO v_req
  FROM public.profile_edit_requests r
  WHERE r.id = p_request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'request not found';
  END IF;

  UPDATE public.profile_edit_requests
  SET
    status = v_decision,
    reviewed_at = now(),
    reviewed_by = auth.uid(),
    reviewer_note = NULLIF(trim(p_reviewer_note), '')
  WHERE id = p_request_id;

  SELECT c.data_type, c.udt_name INTO v_user_fields_type, v_user_fields_udt
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'users'
    AND c.column_name = 'editable_profile_fields';

  v_req_fields := COALESCE(v_req.requested_fields, '{}'::text[]);

  IF v_user_fields_type = 'ARRAY' AND v_user_fields_udt = '_text' THEN
    SELECT COALESCE(u.editable_profile_fields, '{}'::text[]) INTO v_cur_fields
    FROM public.users u
    WHERE u.id = v_req.user_id;
  ELSE
    SELECT COALESCE(array_agg(v), '{}'::text[]) INTO v_cur_fields
    FROM (
      SELECT jsonb_array_elements_text(COALESCE(u.editable_profile_fields::jsonb, '[]'::jsonb)) AS v
      FROM public.users u
      WHERE u.id = v_req.user_id
    ) t;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT f), '{}'::text[]) INTO v_keep_fields
  FROM public.profile_edit_requests r2
  CROSS JOIN LATERAL unnest(COALESCE(r2.requested_fields, '{}'::text[])) AS t(f)
  WHERE r2.user_id = v_req.user_id
    AND r2.status = 'approved'
    AND r2.id <> p_request_id
    AND NULLIF(trim(f), '') IS NOT NULL;

  IF v_decision = 'approved' THEN
    SELECT COALESCE(array_agg(DISTINCT f), '{}'::text[]) INTO v_new_fields
    FROM unnest(COALESCE(v_cur_fields, '{}'::text[]) || COALESCE(v_req_fields, '{}'::text[])) AS t(f)
    WHERE NULLIF(trim(f), '') IS NOT NULL;
  ELSE
    SELECT COALESCE(array_agg(DISTINCT f), '{}'::text[]) INTO v_new_fields
    FROM unnest(COALESCE(v_cur_fields, '{}'::text[])) AS t(f)
    WHERE NULLIF(trim(f), '') IS NOT NULL
      AND (
        NOT (f = ANY(COALESCE(v_req_fields, '{}'::text[])))
        OR f = ANY(COALESCE(v_keep_fields, '{}'::text[]))
      );
  END IF;

  IF v_user_fields_type = 'ARRAY' AND v_user_fields_udt = '_text' THEN
    UPDATE public.users
    SET editable_profile_fields = v_new_fields
    WHERE id = v_req.user_id;
  ELSE
    UPDATE public.users
    SET editable_profile_fields = to_jsonb(v_new_fields)
    WHERE id = v_req.user_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_review_profile_edit_request(uuid, text, text) TO authenticated;
