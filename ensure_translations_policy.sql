-- Ensure RLS is enabled on translations table
ALTER TABLE public.translations ENABLE ROW LEVEL SECURITY;

-- Drop existing policy if it exists to avoid conflicts/duplication
DROP POLICY IF EXISTS "Allow public read access to translations" ON public.translations;

-- Create policy for public read access
CREATE POLICY "Allow public read access to translations"
    ON public.translations
    FOR SELECT
    USING (true);

-- Also ensure the anon/authenticated roles have permission to select
GRANT SELECT ON public.translations TO anon, authenticated, service_role;
