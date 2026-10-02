-- Migration: Add match chat-start extension support
-- Purpose: Allow both participants to extend a match's chat-start window by the same amount.
--   - Adds app_config key matches.chat_start_extension_seconds (default 86400, 24h)
--   - Adds columns to matches to track extensions
--   - Creates match_chat_extensions audit table (one row per user per match)
--   - Rewrites cleanup_expired_matches to respect extensions and per-match window snapshot
--   - Creates RPC extend_match_chat_window(p_match_id uuid) for clients
--   - Updates get_user_recent_matches to expose extension fields
--
-- User-facing strings for this feature are inserted in a separate translation migration
-- and have English fallbacks in lib/providers/locale_provider.dart::LocalizationState.

BEGIN;

-- 1) App config: extension amount (seconds). Same amount for both users; reuse window size by default.
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value)
VALUES (
  'matches.chat_start_extension_seconds',
  '86400',
  'duration_seconds',
  'sync',
  'How much time a single extension adds to a match before it expires (seconds). Each participant may extend once, same amount for both.',
  false,
  60,
  604800
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

-- 2) Matches columns: per-match window snapshot + accumulated extensions.
-- chat_start_window_seconds: snapshot of app_config at match creation (null => use app_config default)
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS chat_start_window_seconds integer;
-- Total extension seconds accumulated (sum of all extensions for this match)
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS chat_start_extension_seconds integer NOT NULL DEFAULT 0;
-- How many users have extended (0..2 normally)
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS chat_start_extension_count integer NOT NULL DEFAULT 0;

-- Backfill: for existing rows ensure extension columns are 0 (default already does)
UPDATE public.matches
SET chat_start_extension_seconds = COALESCE(chat_start_extension_seconds, 0),
    chat_start_extension_count = COALESCE(chat_start_extension_count, 0)
WHERE chat_start_extension_seconds IS NULL OR chat_start_extension_count IS NULL;

-- Ensure non-negative
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'matches_chat_start_extension_seconds_nonneg') THEN
    ALTER TABLE public.matches ADD CONSTRAINT matches_chat_start_extension_seconds_nonneg CHECK (chat_start_extension_seconds >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'matches_chat_start_extension_count_nonneg') THEN
    ALTER TABLE public.matches ADD CONSTRAINT matches_chat_start_extension_count_nonneg CHECK (chat_start_extension_count >= 0 AND chat_start_extension_count <= 10);
  END IF;
END$$;

-- 3) Audit table: one row per (match, user) who extended.
CREATE TABLE IF NOT EXISTS public.match_chat_extensions (
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  extension_seconds integer NOT NULL CHECK (extension_seconds > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (match_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_match_chat_extensions_match_id ON public.match_chat_extensions (match_id);
CREATE INDEX IF NOT EXISTS idx_match_chat_extensions_user_id ON public.match_chat_extensions (user_id);

ALTER TABLE public.match_chat_extensions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view match extensions for their matches" ON public.match_chat_extensions;
CREATE POLICY "Users can view match extensions for their matches"
  ON public.match_chat_extensions FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.matches m
      WHERE m.id = match_chat_extensions.match_id
        AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
    )
  );

-- No direct INSERT policy: extensions are created via SECURITY DEFINER RPC extend_match_chat_window
-- Service role bypasses RLS anyway.

-- Snapshot trigger: ensure new matches store the window that was effective at creation
CREATE OR REPLACE FUNCTION public.set_match_window_snapshot()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_cfg int;
BEGIN
  IF NEW.chat_start_window_seconds IS NULL THEN
    SELECT NULLIF(config_value::text,'')::int INTO v_cfg FROM public.app_config WHERE config_key='matches.chat_start_window_seconds' LIMIT 1;
    IF v_cfg IS NULL OR v_cfg <=0 THEN v_cfg := 86400; END IF;
    NEW.chat_start_window_seconds := v_cfg;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_match_window_snapshot ON public.matches;
CREATE TRIGGER trg_set_match_window_snapshot BEFORE INSERT ON public.matches FOR EACH ROW EXECUTE FUNCTION public.set_match_window_snapshot();

-- Backfill null snapshots for existing matches (best-effort)
UPDATE public.matches
SET chat_start_window_seconds = COALESCE(
  chat_start_window_seconds,
  (SELECT NULLIF(config_value::text,'')::int FROM public.app_config WHERE config_key='matches.chat_start_window_seconds' LIMIT 1)
)
WHERE chat_start_window_seconds IS NULL;
UPDATE public.matches SET chat_start_window_seconds = 86400 WHERE chat_start_window_seconds IS NULL;

-- 4) Helper to read app_config int with fallback
CREATE OR REPLACE FUNCTION public._match_effective_window_seconds(p_match_row public.matches)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg int;
BEGIN
  IF p_match_row.chat_start_window_seconds IS NOT NULL AND p_match_row.chat_start_window_seconds > 0 THEN
    RETURN p_match_row.chat_start_window_seconds;
  END IF;
  SELECT NULLIF(config_value::text,'')::int INTO v_cfg FROM public.app_config WHERE config_key = 'matches.chat_start_window_seconds' LIMIT 1;
  IF v_cfg IS NULL OR v_cfg <= 0 THEN v_cfg := 86400; END IF;
  RETURN v_cfg;
END;
$$;

CREATE OR REPLACE FUNCTION public._match_effective_extension_seconds(p_match_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE((SELECT chat_start_extension_seconds FROM public.matches WHERE id = p_match_id), 0);
$$;

CREATE OR REPLACE FUNCTION public._match_expires_at(p_match_row public.matches)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_window int;
  v_ext int;
BEGIN
  v_window := public._match_effective_window_seconds(p_match_row);
  v_ext := COALESCE(p_match_row.chat_start_extension_seconds, 0);
  RETURN p_match_row.created_at + make_interval(secs => v_window + v_ext);
END;
$$;

-- 5) Rewrite cleanup_expired_matches to respect per-match window + extensions
DROP FUNCTION IF EXISTS public.cleanup_expired_matches(timestamptz, int);
CREATE OR REPLACE FUNCTION public.cleanup_expired_matches(p_cutoff timestamptz, p_limit int DEFAULT 500)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted int := 0;
  v_window_cfg int;
BEGIN
  -- Fetch current default window for fallback when match has no snapshot
  SELECT NULLIF(config_value::text,'')::int INTO v_window_cfg FROM public.app_config WHERE config_key = 'matches.chat_start_window_seconds' LIMIT 1;
  IF v_window_cfg IS NULL OR v_window_cfg <= 0 THEN v_window_cfg := 86400; END IF;

  WITH locked AS (
    SELECT m.id, m.user1_id, m.user2_id, m.match_type, m.created_at,
           COALESCE(m.chat_start_window_seconds, v_window_cfg) as eff_window,
           COALESCE(m.chat_start_extension_seconds, 0) as eff_ext
    FROM public.matches m
    WHERE m.match_type IN ('proximity','event','co_motion')
      -- Compute per-match expiry and compare to now(). p_cutoff is kept for backward compat
      -- but we recompute expiry directly. A match is expired when created_at + window + extension < now().
      AND m.created_at + make_interval(secs => COALESCE(m.chat_start_window_seconds, v_window_cfg) + COALESCE(m.chat_start_extension_seconds, 0)) < now()
      -- Also respect the caller's p_cutoff as an additional guard when it is tighter than now()-window:
      -- if p_cutoff is in the past and match would otherwise be kept due to extension, we still want the
      -- extension-aware check to be authoritative. So we keep the original condition as OR? Instead, we
      -- simply use the extension-aware check; p_cutoff is documentation only.
    ORDER BY m.created_at
    LIMIT COALESCE(p_limit, 500)
    FOR UPDATE
  ),
  eligible AS (
    SELECT l.*
    FROM locked l
    WHERE NOT EXISTS (
      SELECT 1 FROM public.chat_messages cm
      WHERE cm.match_id = l.id
      LIMIT 1
    )
  ),
  upsert_pairs AS (
    INSERT INTO public.unmatched_pairs (user1_id, user2_id, created_by, created_at, match_type, match_id)
    SELECT
      LEAST(e.user1_id, e.user2_id),
      GREATEST(e.user1_id, e.user2_id),
      '00000000-0000-0000-0000-000000000000'::uuid,
      now(),
      e.match_type,
      e.id
    FROM eligible e
    ON CONFLICT (user1_id, user2_id) DO UPDATE
    SET
      created_by = EXCLUDED.created_by,
      created_at = GREATEST(unmatched_pairs.created_at, EXCLUDED.created_at),
      match_type = COALESCE(unmatched_pairs.match_type, EXCLUDED.match_type),
      match_id = COALESCE(unmatched_pairs.match_id, EXCLUDED.match_id)
    RETURNING 1
  ),
  del_chats AS (
    DELETE FROM public.chats c
    WHERE c.match_id IN (SELECT id FROM eligible)
    RETURNING 1
  ),
  del_user_recent_matches AS (
    DELETE FROM public.user_recent_matches urm
    WHERE urm.match_id IN (SELECT id FROM eligible)
    RETURNING 1
  ),
  del_user_recent_chats AS (
    DELETE FROM public.user_recent_chats urc
    WHERE urc.match_id IN (SELECT id FROM eligible)
    RETURNING 1
  ),
  del_messages AS (
    DELETE FROM public.chat_messages cm
    WHERE cm.match_id IN (SELECT id FROM eligible)
    RETURNING 1
  ),
  del_extensions AS (
    DELETE FROM public.match_chat_extensions mce
    WHERE mce.match_id IN (SELECT id FROM eligible)
    RETURNING 1
  ),
  del_matches AS (
    DELETE FROM public.matches m
    WHERE m.id IN (SELECT id FROM eligible)
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_deleted FROM del_matches;

  RETURN COALESCE(v_deleted, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.cleanup_expired_matches(timestamptz, int) TO service_role;

-- 6) RPC: extend_match_chat_window
DROP FUNCTION IF EXISTS public.extend_match_chat_window(uuid);
CREATE OR REPLACE FUNCTION public.extend_match_chat_window(p_match_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_match public.matches%ROWTYPE;
  v_has_chat boolean;
  v_already_extended boolean;
  v_extension_seconds int;
  v_window_cfg int;
  v_eff_window int;
  v_expires_at timestamptz;
  v_new_expires_at timestamptz;
  v_count int;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '28000';
  END IF;

  IF p_match_id IS NULL THEN
    RAISE EXCEPTION 'match_id_required' USING ERRCODE = '22004';
  END IF;

  SELECT * INTO v_match FROM public.matches WHERE id = p_match_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'match_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF v_user_id <> v_match.user1_id AND v_user_id <> v_match.user2_id THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_match.match_type NOT IN ('proximity','event','co_motion') THEN
    RAISE EXCEPTION 'match_type_not_allowed' USING ERRCODE = '42501';
  END IF;

  -- If a chat message already exists, the match no longer expires
  SELECT EXISTS (SELECT 1 FROM public.chat_messages cm WHERE cm.match_id = p_match_id LIMIT 1) INTO v_has_chat;
  IF v_has_chat THEN
    RAISE EXCEPTION 'chat_already_started' USING ERRCODE = 'P0001';
  END IF;

  -- Check if user already extended
  SELECT EXISTS (SELECT 1 FROM public.match_chat_extensions mce WHERE mce.match_id = p_match_id AND mce.user_id = v_user_id) INTO v_already_extended;
  IF v_already_extended THEN
    RAISE EXCEPTION 'already_extended' USING ERRCODE = 'P0001';
  END IF;

  -- Fetch extension amount from app_config
  SELECT NULLIF(config_value::text,'')::int INTO v_extension_seconds FROM public.app_config WHERE config_key = 'matches.chat_start_extension_seconds' LIMIT 1;
  IF v_extension_seconds IS NULL OR v_extension_seconds <= 0 THEN
    -- fallback to window size
    SELECT NULLIF(config_value::text,'')::int INTO v_extension_seconds FROM public.app_config WHERE config_key = 'matches.chat_start_window_seconds' LIMIT 1;
    IF v_extension_seconds IS NULL OR v_extension_seconds <= 0 THEN v_extension_seconds := 86400; END IF;
  END IF;

  -- Check expiry: compute current expires_at
  SELECT NULLIF(config_value::text,'')::int INTO v_window_cfg FROM public.app_config WHERE config_key = 'matches.chat_start_window_seconds' LIMIT 1;
  IF v_window_cfg IS NULL OR v_window_cfg <= 0 THEN v_window_cfg := 86400; END IF;
  v_eff_window := COALESCE(v_match.chat_start_window_seconds, v_window_cfg);
  v_expires_at := v_match.created_at + make_interval(secs => v_eff_window + COALESCE(v_match.chat_start_extension_seconds,0));
  IF now() >= v_expires_at THEN
    RAISE EXCEPTION 'match_expired' USING ERRCODE = 'P0001';
  END IF;

  -- Optional cap: max 2 extensions (one per participant) or up to 10 total as per constraint
  SELECT COUNT(*) INTO v_count FROM public.match_chat_extensions WHERE match_id = p_match_id;
  IF v_count >= 10 THEN
    RAISE EXCEPTION 'max_extensions_reached' USING ERRCODE = 'P0001';
  END IF;

  -- Insert extension record
  INSERT INTO public.match_chat_extensions (match_id, user_id, extension_seconds, created_at)
  VALUES (p_match_id, v_user_id, v_extension_seconds, now());

  -- Update matches accumulated extension
  UPDATE public.matches
  SET chat_start_extension_seconds = COALESCE(chat_start_extension_seconds,0) + v_extension_seconds,
      chat_start_extension_count = COALESCE(chat_start_extension_count,0) + 1
  WHERE id = p_match_id
  RETURNING * INTO v_match;

  v_new_expires_at := v_match.created_at + make_interval(secs => COALESCE(v_match.chat_start_window_seconds, v_window_cfg) + COALESCE(v_match.chat_start_extension_seconds,0));

  RETURN jsonb_build_object(
    'match_id', v_match.id,
    'extension_seconds', v_extension_seconds,
    'total_extension_seconds', v_match.chat_start_extension_seconds,
    'extension_count', v_match.chat_start_extension_count,
    'chat_start_window_seconds', COALESCE(v_match.chat_start_window_seconds, v_window_cfg),
    'expires_at', v_new_expires_at,
    'created_at', v_match.created_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.extend_match_chat_window(uuid) TO authenticated;

-- 7) Update get_user_recent_matches to expose extension fields + expiry + has_extended flag
DROP FUNCTION IF EXISTS public.get_user_recent_matches(uuid, int);
CREATE OR REPLACE FUNCTION public.get_user_recent_matches(p_user_id uuid, p_limit int DEFAULT 20)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  other_photos text[],
  match_type text,
  matched_intent text,
  last_activity_at timestamptz,
  created_at timestamptz,
  chat_start_window_seconds integer,
  chat_start_extension_seconds integer,
  chat_start_extension_count integer,
  expires_at timestamptz,
  has_extended boolean,
  extension_seconds integer
) AS $$
  SELECT
    urm.match_id,
    urm.other_user_id,
    public.mask_full_name(u.name) as other_name,
    ARRAY(SELECT jsonb_array_elements_text(up.photos)) as other_photos,
    urm.match_type,
    urm.matched_intent,
    urm.last_activity_at,
    urm.created_at,
    m.chat_start_window_seconds,
    COALESCE(m.chat_start_extension_seconds, 0) as chat_start_extension_seconds,
    COALESCE(m.chat_start_extension_count, 0) as chat_start_extension_count,
    m.created_at + make_interval(secs => COALESCE(m.chat_start_window_seconds, 86400) + COALESCE(m.chat_start_extension_seconds,0)) as expires_at,
    EXISTS (SELECT 1 FROM public.match_chat_extensions mce WHERE mce.match_id = urm.match_id AND mce.user_id = p_user_id) as has_extended,
    COALESCE((SELECT extension_seconds FROM public.match_chat_extensions mce2 WHERE mce2.match_id = urm.match_id AND mce2.user_id = p_user_id LIMIT 1), 0) as extension_seconds
  FROM public.user_recent_matches urm
  LEFT JOIN public.matches m ON m.id = urm.match_id
  LEFT JOIN public.users u ON u.id = urm.other_user_id
  LEFT JOIN public.user_profiles up ON up.user_id = urm.other_user_id
  WHERE urm.user_id = p_user_id
  ORDER BY urm.last_activity_at DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, int) TO anon;

-- 8) Helper RPC to get extension status for a single match (used by client before extending)
DROP FUNCTION IF EXISTS public.get_match_extension_status(uuid);
CREATE OR REPLACE FUNCTION public.get_match_extension_status(p_match_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_match public.matches%ROWTYPE;
  v_window_cfg int;
  v_eff_window int;
  v_expires_at timestamptz;
  v_has_chat boolean;
  v_has_extended boolean;
  v_other_has_extended boolean;
  v_other_user_id uuid;
  v_extension_seconds int;
  v_remaining_seconds int;
  v_other_extended_at timestamptz;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;
  SELECT * INTO v_match FROM public.matches WHERE id = p_match_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'match_not_found';
  END IF;
  IF v_user_id <> v_match.user1_id AND v_user_id <> v_match.user2_id THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT NULLIF(config_value::text,'')::int INTO v_window_cfg FROM public.app_config WHERE config_key = 'matches.chat_start_window_seconds' LIMIT 1;
  IF v_window_cfg IS NULL OR v_window_cfg <=0 THEN v_window_cfg := 86400; END IF;
  SELECT NULLIF(config_value::text,'')::int INTO v_extension_seconds FROM public.app_config WHERE config_key = 'matches.chat_start_extension_seconds' LIMIT 1;
  IF v_extension_seconds IS NULL OR v_extension_seconds <=0 THEN v_extension_seconds := v_window_cfg; END IF;

  v_eff_window := COALESCE(v_match.chat_start_window_seconds, v_window_cfg);
  v_expires_at := v_match.created_at + make_interval(secs => v_eff_window + COALESCE(v_match.chat_start_extension_seconds,0));
  v_remaining_seconds := GREATEST(0, EXTRACT(EPOCH FROM (v_expires_at - now()))::int);

  SELECT EXISTS (SELECT 1 FROM public.chat_messages cm WHERE cm.match_id = p_match_id LIMIT 1) INTO v_has_chat;
  SELECT EXISTS (SELECT 1 FROM public.match_chat_extensions mce WHERE mce.match_id = p_match_id AND mce.user_id = v_user_id) INTO v_has_extended;
  v_other_user_id := CASE WHEN v_match.user1_id = v_user_id THEN v_match.user2_id ELSE v_match.user1_id END;
  SELECT EXISTS (SELECT 1 FROM public.match_chat_extensions mce WHERE mce.match_id = p_match_id AND mce.user_id = v_other_user_id) INTO v_other_has_extended;

  RETURN jsonb_build_object(
    'match_id', v_match.id,
    'created_at', v_match.created_at,
    'chat_start_window_seconds', v_eff_window,
    'chat_start_extension_seconds', COALESCE(v_match.chat_start_extension_seconds,0),
    'chat_start_extension_count', COALESCE(v_match.chat_start_extension_count,0),
    'expires_at', v_expires_at,
    'remaining_seconds', v_remaining_seconds,
    'has_chat', v_has_chat,
    'has_extended', v_has_extended,
    'other_has_extended', v_other_has_extended,
    'extension_seconds', v_extension_seconds,
    'is_expired', now() >= v_expires_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_match_extension_status(uuid) TO authenticated;

COMMIT;
