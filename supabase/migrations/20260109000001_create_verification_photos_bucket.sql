-- Create storage policies for the verification-photos bucket
-- This bucket was created via Supabase UI and now needs proper RLS policies

-- Ensure RLS is enabled on the storage.objects table
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- Policy: Users can upload their own verification photos
CREATE POLICY "Users can upload their own verification photos" ON storage.objects
FOR INSERT WITH CHECK (
  bucket_id = 'verification-photos'
  AND name LIKE auth.uid() || '/verification.jpg'
);

-- Policy: Users can view their own verification photos
CREATE POLICY "Users can view their own verification photos" ON storage.objects
FOR SELECT USING (
  bucket_id = 'verification-photos'
  AND name LIKE auth.uid() || '/verification.jpg'
);

-- Policy: Service role can view all verification photos (for admin review)
CREATE POLICY "Service role can view all verification photos" ON storage.objects
FOR SELECT USING (
  bucket_id = 'verification-photos'
  AND auth.role() = 'service_role'
);

-- Policy: Users can update their own verification photos
CREATE POLICY "Users can update their own verification photos" ON storage.objects
FOR UPDATE USING (
  bucket_id = 'verification-photos'
  AND name LIKE auth.uid() || '/verification.jpg'
);

-- Policy: Users can delete their own verification photos
CREATE POLICY "Users can delete their own verification photos" ON storage.objects
FOR DELETE USING (
  bucket_id = 'verification-photos'
  AND name LIKE auth.uid() || '/verification.jpg'
);

-- Policy: Service role can manage all verification photos (for cleanup)
CREATE POLICY "Service role can manage all verification photos" ON storage.objects
FOR ALL USING (
  bucket_id = 'verification-photos'
  AND auth.role() = 'service_role'
);