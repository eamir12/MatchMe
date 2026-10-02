BEGIN;

-- Create table to store email codes for sensitive actions
CREATE TABLE IF NOT EXISTS public.sensitive_action_email_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL,
  code text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  expires_at timestamp with time zone NOT NULL,
  used_at timestamp with time zone,
  CONSTRAINT email_code_not_empty CHECK (code != ''),
  CONSTRAINT email_not_empty CHECK (email != '')
);

-- Create index for efficient lookups
CREATE INDEX idx_sensitive_action_email_codes_user_id 
  ON public.sensitive_action_email_codes(user_id);
CREATE INDEX idx_sensitive_action_email_codes_expires_at 
  ON public.sensitive_action_email_codes(expires_at);

-- Enable RLS
ALTER TABLE public.sensitive_action_email_codes ENABLE ROW LEVEL SECURITY;

-- RLS Policy: Users can only see their own codes
CREATE POLICY "Users can view their own email codes"
  ON public.sensitive_action_email_codes
  FOR SELECT
  USING (auth.uid() = user_id);

-- RLS Policy: Service role can insert codes
CREATE POLICY "Service role can insert email codes"
  ON public.sensitive_action_email_codes
  FOR INSERT
  WITH CHECK (true);

-- RLS Policy: Service role can update codes (mark as used)
CREATE POLICY "Service role can update email codes"
  ON public.sensitive_action_email_codes
  FOR UPDATE
  USING (true)
  WITH CHECK (true);

-- Function to generate and store email code
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
  
  -- Insert the code
  INSERT INTO public.sensitive_action_email_codes (user_id, email, code, expires_at)
  VALUES (p_user_id, p_email, v_code, v_expires_at);
  
  RETURN QUERY SELECT v_code, v_expires_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to verify email code
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
  v_expires_at timestamp with time zone;
  v_used_at timestamp with time zone;
BEGIN
  -- Find the most recent unused code for this user and email
  SELECT code, expires_at, used_at
  INTO v_stored_code, v_expires_at, v_used_at
  FROM public.sensitive_action_email_codes
  WHERE user_id = p_user_id 
    AND email = LOWER(p_email)
    AND used_at IS NULL
  ORDER BY created_at DESC
  LIMIT 1;
  
  -- Check if code exists
  IF v_stored_code IS NULL THEN
    RETURN QUERY SELECT false, 'No valid email code found'::text;
    RETURN;
  END IF;
  
  -- Check if code has expired
  IF now() > v_expires_at THEN
    RETURN QUERY SELECT false, 'Email code has expired'::text;
    RETURN;
  END IF;
  
  -- Check if code matches
  IF v_stored_code != p_code THEN
    RETURN QUERY SELECT false, 'Invalid email code'::text;
    RETURN;
  END IF;
  
  -- Mark code as used
  UPDATE public.sensitive_action_email_codes
  SET used_at = now()
  WHERE user_id = p_user_id 
    AND email = LOWER(p_email)
    AND code = p_code
    AND used_at IS NULL;
  
  RETURN QUERY SELECT true, 'Email code verified successfully'::text;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to clean up expired codes (can be called by a cron job)
CREATE OR REPLACE FUNCTION public.cleanup_expired_email_codes()
RETURNS TABLE (
  deleted_count bigint
) AS $$
DECLARE
  v_deleted_count bigint;
BEGIN
  DELETE FROM public.sensitive_action_email_codes
  WHERE expires_at < now();
  
  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  
  RETURN QUERY SELECT v_deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;
