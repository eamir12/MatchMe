-- Grant service role permission to read app_config table
-- This allows Edge Functions to read configuration values

GRANT SELECT ON app_config TO service_role;

-- Verify the grant
SELECT grantee, privilege_type 
FROM information_schema.role_table_grants 
WHERE table_name = 'app_config' AND grantee = 'service_role';
