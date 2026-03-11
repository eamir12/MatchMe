BEGIN;

DROP POLICY IF EXISTS "Admins can delete all profile edit attachments" ON storage.objects;

CREATE POLICY "Admins can delete all profile edit attachments"
ON storage.objects
FOR DELETE
TO PUBLIC
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
