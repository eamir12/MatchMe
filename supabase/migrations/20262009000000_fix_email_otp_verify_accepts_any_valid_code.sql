-- Fix email OTP verification so a correct, just-received code is accepted.
--
-- Root causes fixed:
-- 1) verify_sensitive_action_email_code() only compared the SINGLE most recent
--    code. If the user requested/resent twice (double-tap, auto-send + manual
--    resend), the first email's correct code was rejected as "Invalid" even
--    though it was unexpired. Now ANY unexpired, unused code for the
--    user+email is accepted (matched by code), consistent with the
--    pending_email_changes flow.
-- 2) Copy/paste artifacts (spaces, dashes, newlines) made a correct code
--    mismatch. The function now sanitizes p_code server-side the same way the
--    app does (OtpUtils.sanitizeCode strips separators client-side).
-- 3) generate_sensitive_action_email_code() stored p_email as-is while verify
--    compared LOWER(p_email), so mixed-case storage could never match. Store
--    LOWER() consistently.
-- 4) Ensure authenticated users can EXECUTE the verify/get_active RPCs
--    (explicit contract, future-proof against hardening regressions).

BEGIN;

-- Store emails lowercased so verify lookups always match.
CREATE OR REPLACE FUNCTION public.generate_sensitive_action_email_code(
  p_user_id uuid,
  p_email text
)
RETURNS TABLE (
  code text,
  expires_at timestamp with time zone
) AS $$
DECLARE
  v_code text;
  v_expires_at timestamp with time zone;
BEGIN
  -- Generate a random 6-digit code (preserves leading zeros as text).
  v_code := LPAD((random() * 999999)::int::text, 6, '0');
  v_expires_at := now() + interval '10 minutes';

  INSERT INTO public.sensitive_action_email_codes (user_id, email, encrypted_code, expires_at)
  VALUES (
    p_user_id,
    LOWER(TRIM(p_email)),
    pgp_sym_encrypt(v_code, 'MATCHME_INTERNAL_SECRET'),
    v_expires_at
  );

  RETURN QUERY SELECT v_code, v_expires_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Accept ANY valid (unused, unexpired) code for the user+email, not just the
-- latest one. Sanitizes pasted codes server-side.
CREATE OR REPLACE FUNCTION public.verify_sensitive_action_email_code(
  p_user_id uuid,
  p_email text,
  p_code text
)
RETURNS TABLE (
  success boolean,
  message text
) AS $$
DECLARE
  v_code text;
  v_record record;
BEGIN
  -- Sanitize: strip whitespace/dashes users paste from email clients.
  -- (The app strips a wider unicode set client-side via OtpUtils.)
  v_code := regexp_replace(COALESCE(TRIM(p_code), ''), '[[:space:]\-_]+', '', 'g');

  IF v_code IS NULL OR v_code = '' THEN
    RETURN QUERY SELECT false, 'Invalid email code'::text;
    RETURN;
  END IF;

  -- Find the matching unused, unexpired code (any recent one, newest first).
  SELECT
    id,
    pgp_sym_decrypt(encrypted_code, 'MATCHME_INTERNAL_SECRET')::text AS decrypted_code,
    expires_at
  INTO v_record
  FROM public.sensitive_action_email_codes
  WHERE user_id = p_user_id
    AND email = LOWER(TRIM(p_email))
    AND used_at IS NULL
    AND expires_at > now()
    AND pgp_sym_decrypt(encrypted_code, 'MATCHME_INTERNAL_SECRET')::text = v_code
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_record IS NULL THEN
    -- Distinguish expired (a code exists but all expired) from invalid so
    -- the app can show the right message instead of a generic "incorrect".
    IF EXISTS (
      SELECT 1
      FROM public.sensitive_action_email_codes
      WHERE user_id = p_user_id
        AND email = LOWER(TRIM(p_email))
        AND used_at IS NULL
        AND expires_at <= now()
    ) THEN
      RETURN QUERY SELECT false, 'Email code has expired'::text;
      RETURN;
    END IF;
    RETURN QUERY SELECT false, 'Invalid email code'::text;
    RETURN;
  END IF;

  UPDATE public.sensitive_action_email_codes
  SET used_at = now()
  WHERE id = v_record.id;

  RETURN QUERY SELECT true, 'Code verified successfully'::text;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Harden the plaintext pending_email_changes flow the same way (sanitize).
CREATE OR REPLACE FUNCTION public.verify_email_change_code(
  p_user_id uuid,
  p_code text
)
RETURNS TABLE (success boolean, message text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_code text;
  v_record public.pending_email_changes;
BEGIN
  v_code := regexp_replace(COALESCE(TRIM(p_code), ''), '[[:space:]\-_]+', '', 'g');

  SELECT * INTO v_record
  FROM public.pending_email_changes
  WHERE user_id = p_user_id
    AND regexp_replace(COALESCE(code, ''), '[[:space:]\-_]+', '', 'g') = v_code
    AND verified_at IS NULL
    AND completed_at IS NULL
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, 'Invalid or expired verification code';
    RETURN;
  END IF;

  IF v_record.expires_at < now() THEN
    RETURN QUERY SELECT false, 'Verification code has expired';
    RETURN;
  END IF;

  UPDATE public.pending_email_changes
  SET verified_at = now()
  WHERE id = v_record.id;

  RETURN QUERY SELECT true, 'Code verified successfully';
END;
$$;

-- Explicit contract: authenticated app users may call these OTP RPCs.
GRANT EXECUTE ON FUNCTION public.generate_sensitive_action_email_code(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_sensitive_action_email_code(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_active_sensitive_action_email_code(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_email_change_code(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_email_change_code(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_email_change(uuid, text) TO authenticated;

COMMIT;
