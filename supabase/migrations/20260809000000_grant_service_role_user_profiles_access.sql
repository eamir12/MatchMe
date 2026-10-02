-- Grant service_role access to user_profiles.
--
-- Edge functions (validate-primary-photo, validate-secondary-photo, cron-jobs,
-- compare-verification-photos) run with the service role key and update
-- user_profiles directly (e.g. approved_primary_photos). user_profiles was
-- never granted to service_role, so these writes fail with
-- "42501 permission denied for table user_profiles".

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.user_profiles TO service_role;
