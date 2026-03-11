BEGIN;

ALTER TABLE IF EXISTS public.profile_edit_requests
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

UPDATE public.profile_edit_requests
SET updated_at = COALESCE(updated_at, created_at, now())
WHERE updated_at IS NULL;

COMMIT;
