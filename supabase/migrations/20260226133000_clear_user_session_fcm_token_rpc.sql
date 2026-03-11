BEGIN;

CREATE OR REPLACE FUNCTION public.clear_user_session_fcm_token(p_fcm_token text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_token text;
  v_count integer := 0;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_token := NULLIF(btrim(COALESCE(p_fcm_token, '')), '');
  IF v_token IS NULL THEN
    RETURN 0;
  END IF;

  UPDATE public.user_session
  SET metadata = (COALESCE(metadata, '{}'::jsonb) - 'fcm_token' - 'fcm_token_updated_at')
  WHERE NULLIF(btrim(COALESCE(metadata->>'fcm_token', '')), '') = v_token;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

COMMIT;
