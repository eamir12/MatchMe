-- Check app_config policies
SELECT tablename, policyname, cmd, roles FROM pg_policies 
WHERE schemaname = 'public' AND tablename = 'app_config';