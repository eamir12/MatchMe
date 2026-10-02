BEGIN;

-- Enable pgcrypto extension if not already enabled
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Enable vault extension for secret management
CREATE EXTENSION IF NOT EXISTS supabase_vault;

-- Add encrypted_code column to store encrypted codes
ALTER TABLE public.sensitive_action_email_codes
ADD COLUMN IF NOT EXISTS encrypted_code bytea;

-- Drop existing functions to recreate them with new signatures
DROP FUNCTION IF EXISTS public.verify_sensitive_action_email_code(uuid, text, text);
DROP FUNCTION IF EXISTS public.get_active_sensitive_action_email_code(uuid, text);
DROP FUNCTION IF EXISTS public.generate_sensitive_action_email_code(uuid, text);
DROP FUNCTION IF EXISTS public.cleanup_expired_email_codes();

-- Update the generate_sensitive_action_email_code function to encrypt codes
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
  -- Generate a random 6-digit code
  v_code := LPAD((random() * 999999)::int::text, 6, '0');
  v_expires_at := now() + interval '10 minutes';
  
  -- Insert the code with encryption using MATCHME_INTERNAL_SECRET
  INSERT INTO public.sensitive_action_email_codes (user_id, email, encrypted_code, expires_at)
  VALUES (
    p_user_id, 
    p_email, 
    pgp_sym_encrypt(v_code, 'MATCHME_INTERNAL_SECRET'),
    v_expires_at
  );
  
  RETURN QUERY SELECT v_code, v_expires_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Update the verify_sensitive_action_email_code function to decrypt and compare
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
  v_stored_code text;
  v_code_record record;
BEGIN
  -- Find the most recent unused code for this user and email that hasn't expired
  SELECT 
    pgp_sym_decrypt(encrypted_code, 'MATCHME_INTERNAL_SECRET')::text as decrypted_code,
    id,
    expires_at
  INTO v_code_record
  FROM public.sensitive_action_email_codes
  WHERE user_id = p_user_id 
    AND email = LOWER(p_email)
    AND used_at IS NULL
    AND expires_at > now()
  ORDER BY created_at DESC
  LIMIT 1;
  
  -- Check if code was found
  IF v_code_record IS NULL THEN
    RETURN QUERY SELECT false, 'No valid code found for this email';
    RETURN;
  END IF;
  
  -- Compare the provided code with the decrypted stored code
  IF v_code_record.decrypted_code = p_code THEN
    -- Mark the code as used
    UPDATE public.sensitive_action_email_codes
    SET used_at = now()
    WHERE id = v_code_record.id;
    
    RETURN QUERY SELECT true, 'Code verified successfully';
  ELSE
    RETURN QUERY SELECT false, 'Invalid code';
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Update the get_active_sensitive_action_email_code function to work with encrypted codes
CREATE OR REPLACE FUNCTION public.get_active_sensitive_action_email_code(
  p_user_id uuid,
  p_email text
)
RETURNS TABLE (
  code text,
  created_at timestamp with time zone,
  expires_at timestamp with time zone
) AS $$
BEGIN
  -- Find the most recent unused code for this user and email that hasn't expired
  RETURN QUERY
  SELECT 
    pgp_sym_decrypt(encrypted_code, 'MATCHME_INTERNAL_SECRET')::text as code,
    sensitive_action_email_codes.created_at,
    sensitive_action_email_codes.expires_at
  FROM public.sensitive_action_email_codes
  WHERE sensitive_action_email_codes.user_id = p_user_id 
    AND sensitive_action_email_codes.email = LOWER(p_email)
    AND sensitive_action_email_codes.used_at IS NULL
    AND sensitive_action_email_codes.expires_at > now()
  ORDER BY sensitive_action_email_codes.created_at DESC
  LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create function to cleanup expired email codes (15 minutes after creation)
CREATE OR REPLACE FUNCTION public.cleanup_expired_email_codes()
RETURNS TABLE (
  deleted_count int
) AS $$
DECLARE
  v_deleted_count int;
BEGIN
  -- Delete codes that have expired (15 minutes after creation)
  DELETE FROM public.sensitive_action_email_codes
  WHERE created_at < now() - interval '15 minutes';
  
  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  
  RETURN QUERY SELECT v_deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;
