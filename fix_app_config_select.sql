-- Add SELECT policy for authenticated users on app_config (bypass is_admin check temporarily)
DROP POLICY IF EXISTS "Authenticated can read app_config" ON public.app_config;
CREATE POLICY "Authenticated can read app_config" ON public.app_config
FOR SELECT TO authenticated USING (true);

-- Also check is_admin_user function returns true for the user
SELECT public.is_admin_user() as should_be_true;