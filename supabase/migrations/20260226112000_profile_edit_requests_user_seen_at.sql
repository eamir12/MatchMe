BEGIN;

ALTER TABLE IF EXISTS public.profile_edit_requests
  ADD COLUMN IF NOT EXISTS user_seen_at timestamptz;

ALTER TABLE public.profile_edit_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can update request seen at" ON public.profile_edit_requests;
CREATE POLICY "Users can update request seen at" ON public.profile_edit_requests
FOR UPDATE
USING (user_id = (select auth.uid()))
WITH CHECK (user_id = (select auth.uid()));

GRANT UPDATE (user_seen_at) ON public.profile_edit_requests TO authenticated;

COMMIT;
