-- Fix overload conflict: admin_search_users already exists as (text, int, int) for broadcasts.
-- Previous match-inspector migrations created a second overload (text, int) with different
-- return columns, causing PostgREST PGRST203 Multiple Choices.
-- Solution: drop the 2-arg overload and create a uniquely named function for match inspector.
BEGIN;

-- Drop the 2-arg overloads created by the two previous match-inspector migrations
DROP FUNCTION IF EXISTS public.admin_search_users(text, integer);
DROP FUNCTION IF EXISTS public.admin_search_users(text, integer, integer) CASCADE;
-- Recreate the original broadcast-specific admin_search_users (3 args) exactly as it was
-- (restored to avoid CASCADE side-effects on grants)
CREATE OR REPLACE FUNCTION public.admin_search_users(
  p_query text,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  user_id uuid,
  name text,
  platform text,
  last_active_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_allowed boolean;
  v_limit integer;
  v_offset integer;
  q text;
BEGIN
  IF auth.role() = 'service_role' THEN
    v_is_allowed := true;
  ELSE
    SELECT EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = true
    ) INTO v_is_allowed;
  END IF;

  IF NOT COALESCE(v_is_allowed, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_limit := GREATEST(LEAST(COALESCE(p_limit, 50), 200), 1);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);
  q := btrim(COALESCE(p_query, ''));

  RETURN QUERY
  SELECT *
  FROM (
    SELECT DISTINCT ON (u.id)
      u.id AS user_id,
      u.name,
      us.platform,
      us.last_active_at
    FROM public.users u
    JOIN public.user_session us ON u.id = us.user_id
    WHERE us.revoked = false
      AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
      AND COALESCE((u.notification_preferences->'global_methods'->>'push')::boolean, true) = true
      AND COALESCE(
        (u.notification_preferences->'matrix'->'admin_announcements'->>'push')::boolean,
        (u.notification_preferences->>'enable_admin_notifications')::boolean,
        true
      ) = true
      AND (
        q = '' OR
        u.id::text ILIKE ('%' || q || '%') OR
        COALESCE(u.name, '') ILIKE ('%' || q || '%')
      )
    ORDER BY u.id, us.last_active_at DESC NULLS LAST
  ) t
  ORDER BY t.last_active_at DESC NULLS LAST, t.user_id DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$$;

-- New uniquely named function for Match Inspector (avoids overload)
CREATE OR REPLACE FUNCTION public.admin_search_match_users(
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

GRANT EXECUTE ON FUNCTION public.admin_search_users(text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_search_users(text, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_search_match_users(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_search_match_users(text, integer) TO service_role;

COMMIT;
