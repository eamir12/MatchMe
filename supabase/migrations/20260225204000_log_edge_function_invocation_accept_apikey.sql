BEGIN;

CREATE OR REPLACE FUNCTION public.log_edge_function_invocation(
  p_request_id uuid,
  p_function_name text,
  p_duration_ms integer DEFAULT NULL,
  p_success boolean DEFAULT true,
  p_http_status integer DEFAULT NULL,
  p_error_type text DEFAULT NULL,
  p_error_message text DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_ai_used boolean DEFAULT false,
  p_ai_provider text DEFAULT NULL,
  p_ai_model text DEFAULT NULL,
  p_ai_task text DEFAULT NULL,
  p_meta jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_headers jsonb;
  v_authz text;
  v_apikey text;
BEGIN
  v_headers := COALESCE(current_setting('request.headers', true), '{}'::text)::jsonb;
  v_authz := COALESCE(v_headers ->> 'authorization', v_headers ->> 'Authorization');
  v_apikey := COALESCE(v_headers ->> 'apikey', v_headers ->> 'x-api-key', v_headers ->> 'X-Api-Key');

  IF (v_authz IS NULL OR btrim(v_authz) = '')
     AND (v_apikey IS NULL OR btrim(v_apikey) = '') THEN
    RAISE EXCEPTION 'missing_auth';
  END IF;

  INSERT INTO public.edge_function_invocations (
    request_id,
    function_name,
    duration_ms,
    success,
    http_status,
    error_type,
    error_message,
    user_id,
    ai_used,
    ai_provider,
    ai_model,
    ai_task,
    meta
  ) VALUES (
    p_request_id,
    COALESCE(NULLIF(btrim(COALESCE(p_function_name, '')), ''), 'unknown'),
    p_duration_ms,
    COALESCE(p_success, true),
    p_http_status,
    NULLIF(btrim(COALESCE(p_error_type, '')), ''),
    NULLIF(btrim(COALESCE(p_error_message, '')), ''),
    p_user_id,
    COALESCE(p_ai_used, false),
    NULLIF(btrim(COALESCE(p_ai_provider, '')), ''),
    NULLIF(btrim(COALESCE(p_ai_model, '')), ''),
    NULLIF(btrim(COALESCE(p_ai_task, '')), ''),
    COALESCE(p_meta, '{}'::jsonb)
  );
END;
$$;

COMMIT;

