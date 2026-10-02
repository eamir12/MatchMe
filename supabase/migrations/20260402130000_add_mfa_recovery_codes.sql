BEGIN;

CREATE TABLE IF NOT EXISTS public.user_mfa_recovery_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  code_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  used_at timestamptz,
  UNIQUE (user_id, code_hash)
);

CREATE INDEX IF NOT EXISTS idx_user_mfa_recovery_codes_user_active
  ON public.user_mfa_recovery_codes (user_id, used_at);

ALTER TABLE public.user_mfa_recovery_codes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_mfa_recovery_codes_select_own ON public.user_mfa_recovery_codes;
CREATE POLICY user_mfa_recovery_codes_select_own
  ON public.user_mfa_recovery_codes
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

CREATE OR REPLACE FUNCTION public._format_mfa_recovery_code(p_raw text)
RETURNS text
LANGUAGE sql
AS $$
  SELECT upper(
    substr(p_raw, 1, 4) || '-' ||
    substr(p_raw, 5, 4) || '-' ||
    substr(p_raw, 9, 4) || '-' ||
    substr(p_raw, 13, 4)
  );
$$;

CREATE OR REPLACE FUNCTION public._normalize_mfa_recovery_code(p_code text)
RETURNS text
LANGUAGE sql
AS $$
  SELECT upper(regexp_replace(COALESCE(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
$$;

CREATE OR REPLACE FUNCTION public._hash_mfa_recovery_code(
  p_user_id uuid,
  p_normalized_code text
)
RETURNS text
LANGUAGE sql
AS $$
  SELECT encode(extensions.digest(COALESCE(p_normalized_code, '') || ':' || p_user_id::text, 'sha256'), 'hex');
$$;

CREATE OR REPLACE FUNCTION public.get_mfa_recovery_code_status()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_available_count integer;
  v_last_generated_at timestamptz;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT COUNT(*)::integer, MAX(created_at)
  INTO v_available_count, v_last_generated_at
  FROM public.user_mfa_recovery_codes
  WHERE user_id = v_user_id
    AND used_at IS NULL;

  RETURN jsonb_build_object(
    'available_count', COALESCE(v_available_count, 0),
    'has_codes', COALESCE(v_available_count, 0) > 0,
    'last_generated_at', v_last_generated_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.clear_mfa_recovery_codes()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_deleted_count integer;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  DELETE FROM public.user_mfa_recovery_codes
  WHERE user_id = v_user_id;

  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  RETURN COALESCE(v_deleted_count, 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.generate_mfa_recovery_codes(
  p_replace_existing boolean DEFAULT true
)
RETURNS TABLE(code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_raw_code text;
  v_normalized_code text;
  v_code_hash text;
  v_inserted_count integer := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF COALESCE(p_replace_existing, true) THEN
    DELETE FROM public.user_mfa_recovery_codes
    WHERE user_id = v_user_id;
  END IF;

  WHILE v_inserted_count < 10 LOOP
    v_raw_code := upper(encode(extensions.gen_random_bytes(8), 'hex'));
    v_normalized_code := public._normalize_mfa_recovery_code(v_raw_code);
    v_code_hash := public._hash_mfa_recovery_code(v_user_id, v_normalized_code);

    BEGIN
      INSERT INTO public.user_mfa_recovery_codes (
        user_id,
        code_hash
      )
      VALUES (
        v_user_id,
        v_code_hash
      );

      code := public._format_mfa_recovery_code(v_normalized_code);
      v_inserted_count := v_inserted_count + 1;
      RETURN NEXT;
    EXCEPTION
      WHEN unique_violation THEN
        CONTINUE;
    END;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.consume_mfa_recovery_code(p_code text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_normalized_code text;
  v_code_hash text;
  v_recovery_code_id uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_normalized_code := public._normalize_mfa_recovery_code(p_code);
  IF length(v_normalized_code) <> 16 THEN
    RETURN false;
  END IF;

  v_code_hash := public._hash_mfa_recovery_code(v_user_id, v_normalized_code);

  SELECT id
  INTO v_recovery_code_id
  FROM public.user_mfa_recovery_codes
  WHERE user_id = v_user_id
    AND code_hash = v_code_hash
    AND used_at IS NULL
  LIMIT 1;

  IF v_recovery_code_id IS NULL THEN
    RETURN false;
  END IF;

  UPDATE public.user_mfa_recovery_codes
  SET used_at = now()
  WHERE id = v_recovery_code_id
    AND used_at IS NULL;

  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_mfa_recovery_code_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_mfa_recovery_codes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_mfa_recovery_codes(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.consume_mfa_recovery_code(text) TO authenticated;

COMMIT;
