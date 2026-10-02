-- Check RLS policies on ad_revenue_events
SELECT policyname, cmd, permissive, roles, qual, with_check 
FROM pg_policies 
WHERE tablename = 'ad_revenue_events';

-- Also check current permissions
SELECT grantee, privilege_type FROM information_schema.table_privileges 
WHERE table_name = 'ad_revenue_events';