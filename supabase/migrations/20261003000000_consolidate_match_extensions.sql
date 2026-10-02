-- Migration: Consolidate match chat-start extension tracking into the matches table
-- Purpose:
--   - Moves per-user extension data (who extended, how much, when) from the
--     match_chat_extensions audit table into per-user columns on matches.
--   - No data loss: per-user extension amount AND timestamp are preserved.
--   - Rewrites extend_match_chat_window, get_match_extension_status,
--     get_user_recent_matches and cleanup_expired_matches to use the new columns.
--   - Drops the match_chat_extensions table.

BEGIN;

-- 1) Per-user extension columns on matches.
--    A user has extended when their per-user extension_seconds > 0.
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS chat_start_user1_extension_seconds integer NOT NULL DEFAULT 0;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS chat_start_user2_extension_seconds integer NOT NULL DEFAULT 0;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS chat_start_user1_extended_at timestamptz;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS chat_start_user2_extended_at timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'matches_chat_start_user1_ext_seconds_nonneg') THEN
    ALTER TABLE public.matches ADD CONSTRAINT matches_chat_start_user1_ext_seconds_nonneg CHECK (chat_start_user1_extension_seconds >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'matches_chat_start_user2_ext_seconds_nonneg') THEN
    ALTER TABLE public.matches ADD CONSTRAINT matches_chat_start_user2_ext_seconds_nonneg CHECK (chat_start_user2_extension_seconds >= 0);
  END IF;
END$$;

-- 2) Backfill: copy audit rows into the per-user columns (full fidelity).
UPDATE public.matches m
SET chat_start_user1_extension_seconds = COALESCE((SELECT e.extension_seconds FROM public.match_chat_extensions e WHERE e.match_id = m.id AND e.user_id = m.user1_id LIMIT 1), 0),
    chat_start_user1_extended_at = (SELECT e.created_at FROM public.match_chat_extensions e WHERE e.match_id = m.id AND e.user_id = m.user1_id LIMIT 1),
    chat_start_user2_extension_seconds = COALESCE((SELECT e.extension_seconds FROM public.match_chat_extensions e WHERE e.match_id = m.id AND e.user_id = m.user2_id LIMIT 1), 0),
    chat_start_user2_extended_at = (SELECT e.created_at FROM public.match_chat_extensions e WHERE e.match_id = m.id AND e.user_id = m.user2_id LIMIT 1)
WHERE EXISTS (SELECT 1 FROM public.match_chat_extensions e WHERE e.match_id = m.id);

-- 3) Rewrite extend RPC: enforce one-extension-per-user via per-user columns.
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
  v_is_user1 boolean;
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

  -- Check if user already extended (per-user column, row is locked FOR UPDATE)
  v_is_user1 := (v_user_id = v_match.user1_id);
  v_already_extended := CASE
    WHEN v_is_user1 THEN COALESCE(v_match.chat_start_user1_extension_seconds, 0) > 0
    ELSE COALESCE(v_match.chat_start_user2_extension_seconds, 0) > 0
  END;
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
  v_count := COALESCE(v_match.chat_start_extension_count, 0);
  IF v_count >= 10 THEN
    RAISE EXCEPTION 'max_extensions_reached' USING ERRCODE = 'P0001';
  END IF;

  -- Record the extension per-user (amount + when) and update totals
  UPDATE public.matches
  SET chat_start_user1_extension_seconds = CASE WHEN v_user_id = user1_id THEN v_extension_seconds ELSE COALESCE(chat_start_user1_extension_seconds, 0) END,
      chat_start_user1_extended_at = CASE WHEN v_user_id = user1_id THEN now() ELSE chat_start_user1_extended_at END,
      chat_start_user2_extension_seconds = CASE WHEN v_user_id = user2_id THEN v_extension_seconds ELSE COALESCE(chat_start_user2_extension_seconds, 0) END,
      chat_start_user2_extended_at = CASE WHEN v_user_id = user2_id THEN now() ELSE chat_start_user2_extended_at END,
      chat_start_extension_seconds = COALESCE(chat_start_extension_seconds,0) + v_extension_seconds,
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

-- 4) Rewrite extension status RPC: derive per-user state from matches columns.
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
  v_extension_seconds int;
  v_remaining_seconds int;
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

  v_eff_window := COALESCE(v_match.chat_start_window_seconds, v_window_cfg);
  v_expires_at := v_match.created_at + make_interval(secs => v_eff_window + COALESCE(v_match.chat_start_extension_seconds,0));
  v_remaining_seconds := GREATEST(0, EXTRACT(EPOCH FROM (v_expires_at - now()))::int);

  SELECT EXISTS (SELECT 1 FROM public.chat_messages cm WHERE cm.match_id = p_match_id LIMIT 1) INTO v_has_chat;

  v_has_extended := CASE
    WHEN v_user_id = v_match.user1_id THEN COALESCE(v_match.chat_start_user1_extension_seconds, 0) > 0
    ELSE COALESCE(v_match.chat_start_user2_extension_seconds, 0) > 0
  END;
  v_other_has_extended := CASE
    WHEN v_user_id = v_match.user1_id THEN COALESCE(v_match.chat_start_user2_extension_seconds, 0) > 0
    ELSE COALESCE(v_match.chat_start_user1_extension_seconds, 0) > 0
  END;

  SELECT NULLIF(config_value::text,'')::int INTO v_extension_seconds FROM public.app_config WHERE config_key = 'matches.chat_start_extension_seconds' LIMIT 1;
  IF v_extension_seconds IS NULL OR v_extension_seconds <=0 THEN v_extension_seconds := v_window_cfg; END IF;

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

-- 5) Rewrite get_user_recent_matches: derive has_extended / extension_seconds
--    from the per-user matches columns (was: match_chat_extensions subqueries).
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
  extension_seconds integer,
  match_occurrence integer,
  map_center_lat double precision,
  map_center_lng double precision,
  map_zoom double precision
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
    CASE
      WHEN m.id IS NULL THEN false
      WHEN p_user_id = m.user1_id THEN COALESCE(m.chat_start_user1_extension_seconds, 0) > 0
      ELSE COALESCE(m.chat_start_user2_extension_seconds, 0) > 0
    END as has_extended,
    CASE
      WHEN m.id IS NULL THEN 0
      WHEN p_user_id = m.user1_id THEN COALESCE(m.chat_start_user1_extension_seconds, 0)
      ELSE COALESCE(m.chat_start_user2_extension_seconds, 0)
    END as extension_seconds,
    COALESCE(m.match_occurrence, 1) as match_occurrence,
    m.map_center_lat,
    m.map_center_lng,
    m.map_zoom
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

-- 6) Rewrite cleanup_expired_matches: same logic, minus the audit-table delete.
DROP FUNCTION IF EXISTS public.cleanup_expired_matches(timestamptz, int);
CREATE OR REPLACE FUNCTION public.cleanup_expired_matches(p_cutoff timestamptz, p_limit int DEFAULT 500)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_deleted int := 0;
  v_window_cfg int;
BEGIN
  -- Fetch current default window for fallback when match has no snapshot
  SELECT NULLIF(config_value::text,'')::int INTO v_window_cfg FROM public.app_config WHERE config_key = 'matches.chat_start_window_seconds' LIMIT 1;
  IF v_window_cfg IS NULL OR v_window_cfg <=0 THEN v_window_cfg := 86400; END IF;

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

-- 7) Drop the audit table: all data now lives on public.matches.
DROP TABLE IF EXISTS public.match_chat_extensions;

COMMIT;
