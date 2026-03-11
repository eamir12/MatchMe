BEGIN;

CREATE OR REPLACE FUNCTION public.admin_list_intents()
RETURNS TABLE (
  id integer,
  key text,
  parent_id integer,
  translation_key text,
  sort_order integer,
  is_social boolean,
  is_business boolean,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
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

  RETURN QUERY
  SELECT
    i.id,
    i.key,
    i.parent_id,
    i.translation_key,
    i.sort_order,
    i.is_social,
    i.is_business,
    i.created_at,
    i.updated_at
  FROM public.intents i
  ORDER BY i.sort_order ASC, i.key ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_interests()
RETURNS TABLE (
  id integer,
  key text,
  parent_id integer,
  translation_key text,
  sort_order integer,
  is_social boolean,
  is_business boolean,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
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

  RETURN QUERY
  SELECT
    i.id,
    i.key,
    i.parent_id,
    i.translation_key,
    i.sort_order,
    i.is_social,
    i.is_business,
    i.created_at,
    i.updated_at
  FROM public.interests i
  ORDER BY i.sort_order ASC, i.key ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_upsert_intent(
  p_id integer DEFAULT NULL,
  p_key text DEFAULT NULL,
  p_parent_id integer DEFAULT NULL,
  p_translation_key text DEFAULT NULL,
  p_sort_order integer DEFAULT 0,
  p_is_social boolean DEFAULT false,
  p_is_business boolean DEFAULT false
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_id integer;
  v_key text;
  v_translation_key text;
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

  v_key := NULLIF(trim(p_key), '');
  v_translation_key := NULLIF(trim(p_translation_key), '');

  IF v_key IS NULL THEN
    RAISE EXCEPTION 'p_key is required';
  END IF;

  IF v_translation_key IS NULL THEN
    RAISE EXCEPTION 'p_translation_key is required';
  END IF;

  IF p_id IS NULL OR p_id = 0 THEN
    INSERT INTO public.intents (
      key,
      parent_id,
      translation_key,
      sort_order,
      is_social,
      is_business
    )
    VALUES (
      v_key,
      p_parent_id,
      v_translation_key,
      COALESCE(p_sort_order, 0),
      COALESCE(p_is_social, false),
      COALESCE(p_is_business, false)
    )
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;

  UPDATE public.intents
  SET
    parent_id = p_parent_id,
    translation_key = v_translation_key,
    sort_order = COALESCE(p_sort_order, 0),
    is_social = COALESCE(p_is_social, false),
    is_business = COALESCE(p_is_business, false),
    updated_at = now()
  WHERE id = p_id
  RETURNING id INTO v_id;

  RETURN COALESCE(v_id, 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_upsert_interest(
  p_id integer DEFAULT NULL,
  p_key text DEFAULT NULL,
  p_parent_id integer DEFAULT NULL,
  p_translation_key text DEFAULT NULL,
  p_sort_order integer DEFAULT 0,
  p_is_social boolean DEFAULT false,
  p_is_business boolean DEFAULT false
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_id integer;
  v_key text;
  v_translation_key text;
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

  v_key := NULLIF(trim(p_key), '');
  v_translation_key := NULLIF(trim(p_translation_key), '');

  IF v_key IS NULL THEN
    RAISE EXCEPTION 'p_key is required';
  END IF;

  IF v_translation_key IS NULL THEN
    RAISE EXCEPTION 'p_translation_key is required';
  END IF;

  IF p_id IS NULL OR p_id = 0 THEN
    INSERT INTO public.interests (
      key,
      parent_id,
      translation_key,
      sort_order,
      is_social,
      is_business
    )
    VALUES (
      v_key,
      p_parent_id,
      v_translation_key,
      COALESCE(p_sort_order, 0),
      COALESCE(p_is_social, false),
      COALESCE(p_is_business, false)
    )
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;

  UPDATE public.interests
  SET
    parent_id = p_parent_id,
    translation_key = v_translation_key,
    sort_order = COALESCE(p_sort_order, 0),
    is_social = COALESCE(p_is_social, false),
    is_business = COALESCE(p_is_business, false),
    updated_at = now()
  WHERE id = p_id
  RETURNING id INTO v_id;

  RETURN COALESCE(v_id, 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_intent(p_id integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
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

  IF p_id IS NULL OR p_id = 0 THEN
    RAISE EXCEPTION 'p_id is required';
  END IF;

  IF EXISTS (SELECT 1 FROM public.intents i WHERE i.parent_id = p_id) THEN
    RAISE EXCEPTION 'has children';
  END IF;

  DELETE FROM public.intents WHERE id = p_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_interest(p_id integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
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

  IF p_id IS NULL OR p_id = 0 THEN
    RAISE EXCEPTION 'p_id is required';
  END IF;

  IF EXISTS (SELECT 1 FROM public.interests i WHERE i.parent_id = p_id) THEN
    RAISE EXCEPTION 'has children';
  END IF;

  DELETE FROM public.interests WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_list_intents() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_interests() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_intent(integer, text, integer, text, integer, boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_interest(integer, text, integer, text, integer, boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_intent(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_interest(integer) TO authenticated;

COMMIT;
