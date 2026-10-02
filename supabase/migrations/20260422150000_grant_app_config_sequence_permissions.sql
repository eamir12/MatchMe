-- Grant usage permission on app_config_id_seq to authenticated role
-- This is needed for upsert operations that may insert new rows
GRANT USAGE, SELECT ON SEQUENCE public.app_config_id_seq TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.app_config_id_seq TO anon;
