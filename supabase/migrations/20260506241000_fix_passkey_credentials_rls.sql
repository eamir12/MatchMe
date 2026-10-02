-- Ensure passkey_credentials table has proper RLS policies for authenticated users
-- This fixes 403 errors when users query their own passkey credentials

-- Enable RLS if not already enabled
ALTER TABLE public.passkey_credentials ENABLE ROW LEVEL SECURITY;

-- Drop existing policies to recreate them cleanly
DROP POLICY IF EXISTS "Users can view their own passkey credentials" ON public.passkey_credentials;
DROP POLICY IF EXISTS "Users can delete their own passkey credentials" ON public.passkey_credentials;
DROP POLICY IF EXISTS "service_role can manage passkey_credentials" ON public.passkey_credentials;

-- Create policy for authenticated users to view their own passkey credentials
CREATE POLICY "Users can view their own passkey credentials"
  ON public.passkey_credentials
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Create policy for authenticated users to delete their own passkey credentials
CREATE POLICY "Users can delete their own passkey credentials"
  ON public.passkey_credentials
  FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

-- Create policy for service_role to manage all passkey credentials
CREATE POLICY "service_role can manage passkey_credentials"
  ON public.passkey_credentials
  FOR ALL
  TO service_role
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Ensure service_role has table permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.passkey_credentials TO service_role;