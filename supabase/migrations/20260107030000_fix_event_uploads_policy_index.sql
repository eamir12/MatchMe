-- Migration: Fix event-uploads policy array index
-- Purpose: Use 1-based array index for storage.foldername(name) so auth.uid() comparison succeeds.

-- Drop problematic policies so we can recreate them correctly
DROP POLICY IF EXISTS "Users can upload their own event files" ON storage.objects;
DROP POLICY IF EXISTS "Users can view event uploads" ON storage.objects;
DROP POLICY IF EXISTS "Users can update their own event uploads" ON storage.objects;
DROP POLICY IF EXISTS "Users can delete their own event uploads" ON storage.objects;

-- Recreate with correct array index [1] (Postgres arrays are 1-based)
CREATE POLICY "Users can upload their own event files" ON storage.objects
FOR INSERT TO authenticated WITH CHECK (
  bucket_id = 'event-uploads' AND
  auth.uid()::text = (storage.foldername(name))[1]
);

CREATE POLICY "Users can view event uploads" ON storage.objects
FOR SELECT TO authenticated USING (bucket_id = 'event-uploads');

CREATE POLICY "Users can update their own event uploads" ON storage.objects
FOR UPDATE TO authenticated USING (
  bucket_id = 'event-uploads' AND
  auth.uid()::text = (storage.foldername(name))[1]
);

CREATE POLICY "Users can delete their own event uploads" ON storage.objects
FOR DELETE TO authenticated USING (
  bucket_id = 'event-uploads' AND
  auth.uid()::text = (storage.foldername(name))[1]
);

-- Note: Run this migration in Supabase SQL editor to replace the existing policies. It is safe to run multiple times.
