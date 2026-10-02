-- Fix app_config functions to be VOLATILE instead of STABLE
-- This ensures config changes are reflected immediately in RPC calls

-- Fix app_config_bool
CREATE OR REPLACE FUNCTION public.app_config_bool(
  p_key text,
  p_default boolean
)
RETURNS boolean
LANGUAGE sql
VOLATILE
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT CASE
        WHEN jsonb_typeof(config_value) = 'boolean' THEN (config_value #>> '{}')::boolean
        WHEN jsonb_typeof(config_value) = 'string'
          THEN lower(trim(both '"' FROM config_value::text)) = 'true'
        ELSE NULL
      END
      FROM public.app_config
      WHERE config_key = p_key
      LIMIT 1
    ),
    p_default
  );
$$;

-- Fix app_config_jsonb if it exists
CREATE OR REPLACE FUNCTION public.app_config_jsonb(
  p_key text,
  p_default jsonb
)
RETURNS jsonb
LANGUAGE sql
VOLATILE
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT config_value::jsonb
      FROM public.app_config
      WHERE config_key = p_key
      LIMIT 1
    ),
    p_default
  );
$$;
