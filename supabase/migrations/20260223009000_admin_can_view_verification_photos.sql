BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Admins can view all verification photos'
  ) THEN
    CREATE POLICY "Admins can view all verification photos"
    ON storage.objects
    FOR SELECT
    TO authenticated
    USING (
      bucket_id = 'verification-photos'
      AND EXISTS (
        SELECT 1
        FROM public.users u
        WHERE u.id = auth.uid()
          AND u.is_admin = true
      )
    );
  END IF;
END;
$$;

COMMIT;
