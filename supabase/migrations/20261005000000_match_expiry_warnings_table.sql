-- Migration: Track match expiry warnings server-side for background push
-- Supports background notifications when app is killed and extension-aware re-notify
BEGIN;

CREATE TABLE IF NOT EXISTS public.match_expiry_warnings (
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  threshold_seconds integer NOT NULL CHECK (threshold_seconds > 0),
  expiry_at timestamptz NOT NULL,
  warned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (match_id, user_id, threshold_seconds, expiry_at)
);

CREATE INDEX IF NOT EXISTS idx_match_expiry_warnings_match_id ON public.match_expiry_warnings (match_id);
CREATE INDEX IF NOT EXISTS idx_match_expiry_warnings_user_id ON public.match_expiry_warnings (user_id);
CREATE INDEX IF NOT EXISTS idx_match_expiry_warnings_warned_at ON public.match_expiry_warnings (warned_at);

ALTER TABLE public.match_expiry_warnings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role can manage expiry warnings" ON public.match_expiry_warnings;
CREATE POLICY "Service role can manage expiry warnings"
  ON public.match_expiry_warnings FOR ALL
  TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Users can view own expiry warnings" ON public.match_expiry_warnings;
CREATE POLICY "Users can view own expiry warnings"
  ON public.match_expiry_warnings FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

GRANT ALL ON public.match_expiry_warnings TO service_role;
GRANT SELECT ON public.match_expiry_warnings TO authenticated;

COMMIT;
