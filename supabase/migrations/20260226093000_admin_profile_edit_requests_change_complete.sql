DROP FUNCTION IF EXISTS public.admin_list_profile_edit_requests(text, text, integer, integer);
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
              WHEN v_user_fields_type = 'ARRAY' AND v_user_fields_udt = '_text' THEN
                COALESCE(u.editable_profile_fields, '{}'::text[])
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
