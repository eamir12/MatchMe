-- Fix: Add permissive policies to problem tables
-- Run this in Supabase SQL Editor

-- matches table - ensure authenticated users can access
DROP POLICY IF EXISTS "Allow authenticated access" ON matches;
CREATE POLICY "Allow authenticated access" ON matches
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

-- admin_broadcasts table
DROP POLICY IF EXISTS "Allow authenticated access" ON admin_broadcasts;
CREATE POLICY "Allow authenticated access" ON admin_broadcasts
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

-- Also grant table permissions explicitly
GRANT ALL ON matches TO authenticated;
GRANT ALL ON admin_broadcasts TO authenticated;

SELECT 'Policies recreated successfully' as result;