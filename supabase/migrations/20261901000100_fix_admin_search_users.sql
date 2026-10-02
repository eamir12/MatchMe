-- Fix: admin_search_users was failing with "No users found"
-- Root causes:
-- 1) u.created_at does not exist in public.users (caused ORDER BY error → RPC 500 → client caught and returned [])
-- 2) u.email may not exist in some environments (public.users vs auth.users)
-- 3) client swallowed all errors and showed empty list with no feedback
-- This migration recreates the function without those dependencies and is fully defensive.

BEGIN;

DROP FUNCTION IF EXISTS public.admin_search_users(text, integer);

CREATE OR REPLACE FUNCTION public.admin_search_users(
  p_query text DEFAULT NULL,
  p_limit integer DEFAULT 20
)
RETURNS TABLE (
  id uuid,
  name text,
  email text,
  gender text,
  date_of_birth date,
  photos jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_query text;
  v_limit integer;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_query := NULLIF(trim(COALESCE(p_query, '')), '');
  v_limit := GREATEST(LEAST(COALESCE(p_limit, 20), 100), 1);

  -- Use information_schema to avoid referencing a missing column (email/created_at)
  -- We select email defensively: if column doesn't exist, return empty string.
  -- Build query dynamically so creation succeeds even when column is absent.
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='users' AND column_name='email'
  ) THEN
    RETURN QUERY EXECUTE
      'SELECT
         u.id,
         COALESCE(u.name, '''') AS name,
         COALESCE(u.email, '''') AS email,
         u.gender,
         u.date_of_birth,
         COALESCE(up.photos, ''[]''::jsonb) AS photos
       FROM public.users u
       LEFT JOIN public.user_profiles up ON up.user_id = u.id
       WHERE ($1 IS NULL
         OR u.id::text ILIKE ''%'' || $1 || ''%''
         OR COALESCE(u.name, '''') ILIKE ''%'' || $1 || ''%''
         OR COALESCE(u.email, '''') ILIKE ''%'' || $1 || ''%'')
       ORDER BY
         CASE WHEN $1 IS NULL THEN 0 ELSE
           CASE WHEN COALESCE(u.name,'''') ILIKE $1 || ''%'' THEN 0
                WHEN COALESCE(u.name,'''') ILIKE ''%'' || $1 || ''%'' THEN 1
                ELSE 2 END
         END,
         u.id DESC
       LIMIT $2'
    USING v_query, v_limit;
  ELSE
    RETURN QUERY EXECUTE
      'SELECT
         u.id,
         COALESCE(u.name, '''') AS name,
         ''''::text AS email,
         u.gender,
         u.date_of_birth,
         COALESCE(up.photos, ''[]''::jsonb) AS photos
       FROM public.users u
       LEFT JOIN public.user_profiles up ON up.user_id = u.id
       WHERE ($1 IS NULL
         OR u.id::text ILIKE ''%'' || $1 || ''%''
         OR COALESCE(u.name, '''') ILIKE ''%'' || $1 || ''%'')
       ORDER BY
         CASE WHEN $1 IS NULL THEN 0 ELSE
           CASE WHEN COALESCE(u.name,'''') ILIKE $1 || ''%'' THEN 0
                WHEN COALESCE(u.name,'''') ILIKE ''%'' || $1 || ''%'' THEN 1
                ELSE 2 END
         END,
         u.id DESC
       LIMIT $2'
    USING v_query, v_limit;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_search_users(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_search_users(text, integer) TO service_role;

COMMIT;
