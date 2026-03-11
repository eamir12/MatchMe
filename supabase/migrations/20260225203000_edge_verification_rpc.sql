BEGIN;

CREATE OR REPLACE FUNCTION public.edge_require_internal_secret()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_headers jsonb;
  v_provided text;
  v_expected text;
  v_config_value_type text;
BEGIN
  v_headers := COALESCE(current_setting('request.headers', true), '{}'::text)::jsonb;
  v_provided := COALESCE(
    v_headers ->> 'x-edge-internal-secret',
    v_headers ->> 'X-Edge-Internal-Secret'
  );

  SELECT c.data_type
  INTO v_config_value_type
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'app_config'
    AND c.column_name = 'config_value'
  LIMIT 1;

  IF v_config_value_type IN ('json', 'jsonb') THEN
    EXECUTE
      'SELECT (config_value #>> ''{}'') FROM public.app_config WHERE config_key = $1 LIMIT 1'
    INTO v_expected
    USING 'edge_internal_secret';
  ELSE
    EXECUTE
      'SELECT config_value::text FROM public.app_config WHERE config_key = $1 LIMIT 1'
    INTO v_expected
    USING 'edge_internal_secret';
  END IF;

  IF v_expected IS NULL OR btrim(v_expected) = '' THEN
    RAISE EXCEPTION 'edge_internal_secret_not_configured';
  END IF;

  IF v_provided IS NULL OR v_provided <> v_expected THEN
    RAISE EXCEPTION 'edge_internal_secret_invalid';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.edge_update_verification(
  p_user_id uuid,
  p_patch jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_patch jsonb := COALESCE(p_patch, '{}'::jsonb);
  v_status text;
BEGIN
  PERFORM public.edge_require_internal_secret();

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_id_required';
  END IF;

  IF jsonb_typeof(v_patch) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'invalid_patch';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_object_keys(v_patch) k
    WHERE k NOT IN (
      'verification_photo_path',
      'verification_status',
      'verification_submitted_at',
      'verification_reviewed_at',
      'verification_similarity_score',
      'verification_ai_analysis',
      'verification_auto_rejected',
      'is_verified'
    )
  ) THEN
    RAISE EXCEPTION 'patch_has_disallowed_keys';
  END IF;

  v_status := NULLIF(btrim(COALESCE(v_patch ->> 'verification_status', '')), '');
  IF v_status IS NOT NULL AND v_status NOT IN ('pending', 'analyzing', 'approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid_verification_status';
  END IF;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  UPDATE public.users u
  SET
    verification_photo_path = CASE
      WHEN v_patch ? 'verification_photo_path' THEN NULLIF(btrim(COALESCE(v_patch ->> 'verification_photo_path', '')), '')
      ELSE u.verification_photo_path
    END,
    verification_status = CASE
      WHEN v_patch ? 'verification_status' THEN v_status
      ELSE u.verification_status
    END,
    verification_submitted_at = CASE
      WHEN v_patch ? 'verification_submitted_at' THEN NULLIF(v_patch ->> 'verification_submitted_at', '')::timestamptz
      ELSE u.verification_submitted_at
    END,
    verification_reviewed_at = CASE
      WHEN v_patch ? 'verification_reviewed_at' THEN NULLIF(v_patch ->> 'verification_reviewed_at', '')::timestamptz
      ELSE u.verification_reviewed_at
    END,
    verification_similarity_score = CASE
      WHEN v_patch ? 'verification_similarity_score' THEN NULLIF(v_patch ->> 'verification_similarity_score', '')::numeric
      ELSE u.verification_similarity_score
    END,
    verification_ai_analysis = CASE
      WHEN v_patch ? 'verification_ai_analysis' THEN COALESCE(v_patch -> 'verification_ai_analysis', 'null'::jsonb)
      ELSE u.verification_ai_analysis
    END,
    verification_auto_rejected = CASE
      WHEN v_patch ? 'verification_auto_rejected' THEN COALESCE((v_patch ->> 'verification_auto_rejected')::boolean, false)
      ELSE u.verification_auto_rejected
    END,
    is_verified = CASE
      WHEN v_patch ? 'is_verified' THEN COALESCE((v_patch ->> 'is_verified')::boolean, false)
      ELSE u.is_verified
    END
  WHERE u.id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user_not_found';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.edge_require_internal_secret() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edge_update_verification(uuid, jsonb) TO anon, authenticated;

COMMIT;
