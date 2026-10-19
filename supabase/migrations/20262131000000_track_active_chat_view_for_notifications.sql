-- Track each signed-in app/tab session's currently visible chat. Push senders
-- use fresh rows to avoid creating a tray or inbox notification for a chat
-- the recipient is actively reading. Stale rows are ignored by the edge fn.
CREATE TABLE IF NOT EXISTS public.user_chat_view_state (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  session_id uuid NOT NULL,
  match_id uuid NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  is_active boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, session_id)
);

CREATE INDEX IF NOT EXISTS idx_user_chat_view_state_active_match
  ON public.user_chat_view_state (user_id, match_id, updated_at DESC)
  WHERE is_active = true;

ALTER TABLE public.user_chat_view_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own chat view state"
  ON public.user_chat_view_state;
CREATE POLICY "Users manage own chat view state"
  ON public.user_chat_view_state
  FOR ALL
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.user_chat_view_state TO authenticated;
GRANT ALL ON public.user_chat_view_state TO service_role;
