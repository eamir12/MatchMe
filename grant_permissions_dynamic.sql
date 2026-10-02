-- Grant permissions dynamically - only to existing tables
-- Run this in Supabase SQL Editor

DO $$
DECLARE
    tbl text;
    grant_sql text;
BEGIN
    -- Get all tables in public schema
    FOR tbl IN 
        SELECT tablename::text 
        FROM pg_tables 
        WHERE schemaname = 'public'
        ORDER BY tablename
    LOOP
        BEGIN
            grant_sql := 'GRANT ALL ON ' || tbl || ' TO authenticated';
            EXECUTE grant_sql;
            RAISE NOTICE 'Granted on %', tbl;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Skipped %: %', tbl, SQLERRM;
        END;
    END LOOP;
    
    -- Grant schema permissions
    GRANT USAGE ON SCHEMA public TO authenticated;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
    GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO authenticated;
    
    -- Grant sequence permissions
    FOR tbl IN 
        SELECT sequence_name::text 
        FROM information_schema.sequences
    LOOP
        BEGIN
            grant_sql := 'GRANT ALL ON SEQUENCE ' || tbl || ' TO authenticated';
            EXECUTE grant_sql;
        EXCEPTION WHEN OTHERS THEN
            -- skip
        END;
    END LOOP;
END $$;

SELECT 'Permissions granted to all existing tables' as result;