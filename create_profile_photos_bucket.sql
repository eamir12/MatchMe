-- Supabase Storage Bucket Setup for Profile Photos
--
-- IMPORTANT: Ensure the bucket "profile-photos" is set to PRIVATE (not public)
-- In Supabase Dashboard > Storage > profile-photos > Settings > Make Private
--
-- Then run these policies in the SQL Editor:

-- Drop existing policies if they exist (to fix the foldername index)
DROP POLICY IF EXISTS "Users can upload their own photos" ON storage.objects;
DROP POLICY IF EXISTS "Users can view profile photos" ON storage.objects;
DROP POLICY IF EXISTS "Users can update their own photos" ON storage.objects;
DROP POLICY IF EXISTS "Users can delete their own photos" ON storage.objects;

-- Allow authenticated users to upload to their own folder
CREATE POLICY "Users can upload their own photos" ON storage.objects
FOR INSERT TO authenticated WITH CHECK (
  bucket_id = 'profile-photos' AND
  auth.uid()::text = (storage.foldername(name))[0]
);

-- Allow authenticated users to read all photos (for matching)
CREATE POLICY "Users can view profile photos" ON storage.objects
FOR SELECT TO authenticated USING (bucket_id = 'profile-photos');

-- Allow users to update/delete their own photos
CREATE POLICY "Users can update their own photos" ON storage.objects
FOR UPDATE TO authenticated USING (
  bucket_id = 'profile-photos' AND
  auth.uid()::text = (storage.foldername(name))[0]
);

CREATE POLICY "Users can delete their own photos" ON storage.objects
FOR DELETE TO authenticated USING (
  bucket_id = 'profile-photos' AND
  auth.uid()::text = (storage.foldername(name))[0]
);