BEGIN;

CREATE OR REPLACE FUNCTION public._hash_mfa_recovery_code(
  p_user_id uuid,
  p_normalized_code text
)
RETURNS text
LANGUAGE sql
AS $$
  SELECT encode(extensions.digest(COALESCE(p_normalized_code, '') || ':' || p_user_id::text, 'sha256'), 'hex');
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

GRANT EXECUTE ON FUNCTION public.generate_mfa_recovery_codes(boolean) TO authenticated;

COMMIT;
