BEGIN;

-- Drop existing policies
DROP POLICY IF EXISTS "Users can view their own email codes" ON public.sensitive_action_email_codes;
DROP POLICY IF EXISTS "Service role can insert email codes" ON public.sensitive_action_email_codes;
DROP POLICY IF EXISTS "Service role can update email codes" ON public.sensitive_action_email_codes;

-- Recreate policies with proper service role access
-- Allow authenticated users to view their own codes
CREATE POLICY "Users can view their own email codes"
  ON public.sensitive_action_email_codes
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Allow service role to insert codes (bypass RLS)
CREATE POLICY "Service role can insert email codes"
  ON public.sensitive_action_email_codes
  FOR INSERT
  TO service_role
  WITH CHECK (true);

-- Allow service role to update codes (bypass RLS)
CREATE POLICY "Service role can update email codes"
  ON public.sensitive_action_email_codes
  FOR UPDATE
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Allow service role to select codes (for verification)
CREATE POLICY "Service role can select email codes"
  ON public.sensitive_action_email_codes
  FOR SELECT
  TO service_role
  USING (true);

COMMIT;
