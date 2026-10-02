-- Grant permissions to authenticated role for all tables
-- Run this in Supabase SQL Editor

-- Get all tables in public schema and grant permissions
DO $$
DECLARE
    tbl text;
BEGIN
    FOR tbl IN 
        SELECT tablename 
        FROM pg_tables 
        WHERE schemaname = 'public'
    LOOP
        EXECUTE format('GRANT ALL ON %I TO authenticated', tbl);
        RAISE NOTICE 'Granted permissions on %', tbl;
    END LOOP;
END $$;

-- Also grant permissions on all sequences
DO $$
DECLARE
    seq text;
BEGIN
    FOR seq IN 
        SELECT sequence_name 
        FROM information_schema.sequences
    LOOP
        EXECUTE format('GRANT ALL ON %I TO authenticated', seq);
    END LOOP;
END $$;

-- Grant execute on all functions
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO authenticated;

-- Grant usage on public schema
GRANT USAGE ON SCHEMA public TO authenticated;

SELECT 'Permissions granted successfully' as result;