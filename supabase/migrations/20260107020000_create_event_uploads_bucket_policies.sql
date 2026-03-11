-- Migration: Create storage policies for the 'event-uploads' bucket
-- Purpose: Allow authenticated users to upload files into their own folder in the bucket

-- Drop existing policies (safe to run multiple times)
DROP POLICY IF EXISTS "Users can upload their own event files" ON storage.objects;
DROP POLICY IF EXISTS "Users can view event uploads" ON storage.objects;
DROP POLICY IF EXISTS "Users can update their own event uploads" ON storage.objects;
DROP POLICY IF EXISTS "Users can delete their own event uploads" ON storage.objects;

-- Allow authenticated users to upload to their own folder (folder name = user_id)
CREATE POLICY "Users can upload their own event files" ON storage.objects
FOR INSERT TO authenticated WITH CHECK (
  bucket_id = 'event-uploads' AND
  auth.uid()::text = (storage.foldername(name))[0]
);

-- Allow authenticated users to read objects in the event-uploads bucket (if you want them to be readable)
CREATE POLICY "Users can view event uploads" ON storage.objects
FOR SELECT TO authenticated USING (bucket_id = 'event-uploads');

-- Allow users to update/delete their own uploads (if desired)
CREATE POLICY "Users can update their own event uploads" ON storage.objects
FOR UPDATE TO authenticated USING (
  bucket_id = 'event-uploads' AND
  auth.uid()::text = (storage.foldername(name))[0]
);

CREATE POLICY "Users can delete their own event uploads" ON storage.objects
FOR DELETE TO authenticated USING (
  bucket_id = 'event-uploads' AND
  auth.uid()::text = (storage.foldername(name))[0]
);

-- Notes:
-- 1. Apply this migration in your Supabase SQL editor. If you want files to be public, alternatively set bucket to public in the dashboard.
-- 2. If uploads should be allowed by a server function only (service role), prefer using server-side signed URLs instead of allowing direct client uploads.
