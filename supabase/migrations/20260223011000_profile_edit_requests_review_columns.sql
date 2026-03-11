BEGIN;

ALTER TABLE IF EXISTS public.profile_edit_requests
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz;

ALTER TABLE IF EXISTS public.profile_edit_requests
  ADD COLUMN IF NOT EXISTS reviewed_by uuid REFERENCES auth.users(id);

ALTER TABLE IF EXISTS public.profile_edit_requests
  ADD COLUMN IF NOT EXISTS reviewer_note text;

COMMIT;
