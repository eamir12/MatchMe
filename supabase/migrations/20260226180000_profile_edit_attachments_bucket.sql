BEGIN;

ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

INSERT INTO storage.buckets (id, name, public)
VALUES ('profile-edit-attachments', 'profile-edit-attachments', false)
ON CONFLICT (id) DO NOTHING;

UPDATE storage.buckets
SET public = false
WHERE id = 'profile-edit-attachments';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'storage'
      AND table_name = 'buckets'
      AND column_name = 'file_size_limit'
  ) THEN
    UPDATE storage.buckets
    SET file_size_limit = 10485760
    WHERE id = 'profile-edit-attachments';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'storage'
      AND table_name = 'buckets'
      AND column_name = 'allowed_mime_types'
  ) THEN
    UPDATE storage.buckets
    SET allowed_mime_types = ARRAY[
      'image/jpeg',
      'image/png',
      'image/gif',
      'application/pdf',
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/vnd.ms-excel',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'application/vnd.ms-powerpoint',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation'
    ]::text[]
    WHERE id = 'profile-edit-attachments';
  END IF;
END
$$;

DROP POLICY IF EXISTS "Users can upload their own profile edit attachments" ON storage.objects;
DROP POLICY IF EXISTS "Users can view their own profile edit attachments" ON storage.objects;
DROP POLICY IF EXISTS "Users can update their own profile edit attachments" ON storage.objects;
DROP POLICY IF EXISTS "Users can delete their own profile edit attachments" ON storage.objects;
DROP POLICY IF EXISTS "Admins can view all profile edit attachments" ON storage.objects;

CREATE POLICY "Users can upload their own profile edit attachments" ON storage.objects
FOR INSERT TO authenticated WITH CHECK (
  bucket_id = 'profile-edit-attachments' AND
  auth.uid()::text = (storage.foldername(name))[1]
);

CREATE POLICY "Users can view their own profile edit attachments" ON storage.objects
FOR SELECT TO authenticated USING (
  bucket_id = 'profile-edit-attachments' AND
  auth.uid()::text = (storage.foldername(name))[1]
);

CREATE POLICY "Users can update their own profile edit attachments" ON storage.objects
FOR UPDATE TO authenticated USING (
  bucket_id = 'profile-edit-attachments' AND
  auth.uid()::text = (storage.foldername(name))[1]
);

CREATE POLICY "Users can delete their own profile edit attachments" ON storage.objects
FOR DELETE TO authenticated USING (
  bucket_id = 'profile-edit-attachments' AND
  auth.uid()::text = (storage.foldername(name))[1]
);

CREATE POLICY "Admins can view all profile edit attachments"
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'profile-edit-attachments'
  AND EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  )
);

COMMIT;
