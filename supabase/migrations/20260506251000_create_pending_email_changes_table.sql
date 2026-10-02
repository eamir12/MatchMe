BEGIN;

-- Create pending_email_changes table for email change flow
-- This table was referenced by existing RPC functions but never created in migrations
CREATE TABLE IF NOT EXISTS public.pending_email_changes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  new_email text NOT NULL,
  code text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  expires_at timestamp with time zone NOT NULL,
  verified_at timestamp with time zone,
  completed_at timestamp with time zone,
  CONSTRAINT pending_email_changes_code_not_empty CHECK (code != ''),
  CONSTRAINT pending_email_changes_email_not_empty CHECK (new_email != '')
);

-- Index for efficient cleanup queries
CREATE INDEX IF NOT EXISTS idx_pending_email_changes_expires_at
  ON public.pending_email_changes (expires_at);

-- Index for user lookups
CREATE INDEX IF NOT EXISTS idx_pending_email_changes_user_id
  ON public.pending_email_changes (user_id);

-- Enable RLS
ALTER TABLE public.pending_email_changes ENABLE ROW LEVEL SECURITY;

-- Drop existing policies in case table was created manually
DROP POLICY IF EXISTS "Service role can manage pending email changes" ON public.pending_email_changes;
DROP POLICY IF EXISTS "Service role can update pending email changes" ON public.pending_email_changes;
DROP POLICY IF EXISTS "Users can view their own pending email changes" ON public.pending_email_changes;

-- RLS: service_role can manage all rows
CREATE POLICY "Service role can manage pending email changes"
  ON public.pending_email_changes
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- RLS: service_role can update
CREATE POLICY "Service role can update pending email changes"
  ON public.pending_email_changes
  FOR UPDATE
  TO service_role
  USING (true)
  WITH CHECK (true);

-- RLS: users can view their own pending changes
CREATE POLICY "Users can view their own pending email changes"
  ON public.pending_email_changes
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Drop existing functions first to allow return type changes
DROP FUNCTION IF EXISTS public.generate_email_change_code(uuid, text);
DROP FUNCTION IF EXISTS public.verify_email_change_code(uuid, text);
DROP FUNCTION IF EXISTS public.complete_email_change(uuid, text);

-- Function: generate_email_change_code
CREATE OR REPLACE FUNCTION public.generate_email_change_code(
  p_user_id uuid,
  p_new_email text
)
RETURNS TABLE (code text, expires_at timestamp with time zone)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_code text;
  v_expires_at timestamp with time zone;
BEGIN
  -- Generate a 6-digit code
  v_code := lpad(floor(random() * 1000000)::text, 6, '0');
  v_expires_at := now() + interval '10 minutes';

  -- Insert the pending email change
  INSERT INTO public.pending_email_changes (user_id, new_email, code, expires_at)
  VALUES (p_user_id, p_new_email, v_code, v_expires_at);

  RETURN QUERY SELECT v_code, v_expires_at;
END;
$$;

-- Function: verify_email_change_code
CREATE OR REPLACE FUNCTION public.verify_email_change_code(
  p_user_id uuid,
  p_code text
)
RETURNS TABLE (success boolean, message text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_record public.pending_email_changes;
BEGIN
  SELECT * INTO v_record
  FROM public.pending_email_changes
  WHERE user_id = p_user_id
    AND code = p_code
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

  -- Mark as verified
  UPDATE public.pending_email_changes
  SET verified_at = now()
  WHERE id = v_record.id;

  RETURN QUERY SELECT true, 'Code verified successfully';
END;
$$;

-- Function: complete_email_change
CREATE OR REPLACE FUNCTION public.complete_email_change(
  p_user_id uuid,
  p_code text
)
RETURNS TABLE (success boolean, message text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_record public.pending_email_changes;
BEGIN
  SELECT * INTO v_record
  FROM public.pending_email_changes
  WHERE user_id = p_user_id
    AND code = p_code
    AND verified_at IS NOT NULL
    AND completed_at IS NULL
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, 'No verified email change found for this code';
    RETURN;
  END IF;

  IF v_record.expires_at < now() THEN
    RETURN QUERY SELECT false, 'Verification has expired';
    RETURN;
  END IF;

  -- Mark as completed
  UPDATE public.pending_email_changes
  SET completed_at = now()
  WHERE id = v_record.id;

  RETURN QUERY SELECT true, 'Email change completed successfully';
END;
$$;

-- Drop and re-create cleanup function to ensure it references the correct table
DROP FUNCTION IF EXISTS public.cleanup_pending_email_changes();
CREATE FUNCTION public.cleanup_pending_email_changes()
RETURNS TABLE (deleted_count bigint)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_deleted_count bigint;
BEGIN
  DELETE FROM public.pending_email_changes
  WHERE expires_at < now();

  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

  RETURN QUERY SELECT v_deleted_count;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION public.generate_email_change_code(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_email_change_code(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_email_change(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_pending_email_changes() TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_pending_email_changes() TO postgres;

COMMIT;
