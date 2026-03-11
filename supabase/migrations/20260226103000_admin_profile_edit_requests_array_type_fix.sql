CREATE OR REPLACE FUNCTION public.admin_list_profile_edit_requests(
  p_status text DEFAULT NULL,
  p_query text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  user_name text,
  requested_fields text[],
  message text,
  attachments jsonb,
  status text,
  change_complete boolean,
  created_at timestamptz,
  updated_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid,
  reviewer_note text,
  reviewer_name text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_status text;
  v_query text;
  v_user_fields_type text;
  v_user_fields_udt text;
  v_user_fields_is_array boolean;
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
  v_query := NULLIF(trim(p_query), '');

  SELECT c.data_type, c.udt_name INTO v_user_fields_type, v_user_fields_udt
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'users'
    AND c.column_name = 'editable_profile_fields';

  v_user_fields_is_array := (v_user_fields_type = 'ARRAY');

  RETURN QUERY
  SELECT
    r.id,
    r.user_id,
    u.name AS user_name,
    r.requested_fields,
    r.message,
    r.attachments,
    r.status,
    CASE
      WHEN r.status <> 'approved' THEN false
      WHEN COALESCE(array_length(r.requested_fields, 1), 0) = 0 THEN false
      ELSE NOT EXISTS (
        SELECT 1
        FROM unnest(COALESCE(r.requested_fields, '{}'::text[])) AS rf(field_key)
        WHERE NULLIF(trim(rf.field_key), '') IS NOT NULL
          AND rf.field_key = ANY(
            CASE
              WHEN v_user_fields_is_array THEN
                COALESCE(u.editable_profile_fields::text[], '{}'::text[])
              ELSE (
                SELECT COALESCE(array_agg(v), '{}'::text[])
                FROM (
                  SELECT jsonb_array_elements_text(COALESCE(u.editable_profile_fields::jsonb, '[]'::jsonb)) AS v
                ) t
              )
            END
          )
      )
    END AS change_complete,
    r.created_at,
    r.updated_at,
    r.reviewed_at,
    r.reviewed_by,
    r.reviewer_note,
    COALESCE(ru.name, '') AS reviewer_name
  FROM public.profile_edit_requests r
  JOIN public.users u ON u.id = r.user_id
  LEFT JOIN public.users ru ON ru.id = r.reviewed_by
  WHERE (v_status IS NULL OR r.status = v_status)
    AND (
      v_query IS NULL OR
      r.user_id::text ILIKE '%' || v_query || '%' OR
      COALESCE(u.name, '') ILIKE '%' || v_query || '%' OR
      COALESCE(ru.name, '') ILIKE '%' || v_query || '%' OR
      COALESCE(r.message, '') ILIKE '%' || v_query || '%' OR
      array_to_string(COALESCE(r.requested_fields, '{}'::text[]), ',') ILIKE '%' || v_query || '%'
    )
  ORDER BY r.created_at DESC NULLS LAST, r.id DESC
  LIMIT GREATEST(LEAST(COALESCE(p_limit, 100), 500), 1)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
END;
$$;

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
  v_user_fields_is_array boolean;
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

  v_user_fields_is_array := (v_user_fields_type = 'ARRAY');

  v_req_fields := COALESCE(v_req.requested_fields, '{}'::text[]);

  IF v_user_fields_is_array THEN
    SELECT COALESCE(u.editable_profile_fields::text[], '{}'::text[]) INTO v_cur_fields
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

  IF v_user_fields_is_array THEN
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

GRANT EXECUTE ON FUNCTION public.admin_list_profile_edit_requests(text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_review_profile_edit_request(uuid, text, text) TO authenticated;
