-- Migration: Admin delete match - permanent vs rematch-eligible choice
-- Purpose:
--   Extends admin_delete_match() (created in
--   20261016000000_admin_delete_user_and_match.sql) with a p_permanent flag
--   so the admin chooses, at confirmation time, what happens to the pair:
--
--     p_permanent = true  -> PERMANENT deletion: upserts
--        unmatched_pairs(user1_id, user2_id) with is_permanent = true
--        (ordered pair, admin recorded as creator). The proximity/event
--        matching engines skip pairs with is_permanent = true, and legacy
--        engines skip any existing pair row, so the two users will NEVER
--        be matched again. Mirrors unmatch_from_system_match() semantics.
--
--     p_permanent = false -> REMATCH-ELIGIBLE deletion (default, preserves
--        the previous behaviour): removes the pair's unmatched_pairs row
--        entirely (clean slate), so the system may match the users again
--        naturally (next match starts at occurrence 1).
--
--   Single function signature (old 1-arg overload is dropped first) so
--   PostgREST never sees ambiguous overloads. p_permanent DEFAULT false
--   keeps old single-argument calls working.
--
-- Usage (after applying):
--   SELECT public.admin_delete_match('<match-uuid>');          -- rematch OK
--   SELECT public.admin_delete_match('<match-uuid>', true);    -- never again
--   SELECT public.admin_delete_match('<match-uuid>', false);   -- rematch OK

BEGIN;

-- Drop the previous 1-arg version to avoid PostgREST overload ambiguity
-- (same lesson as the admin_search_users overload fix).
DROP FUNCTION IF EXISTS public.admin_delete_match(uuid);

-- ============================================================================
-- admin_delete_match(p_match_id uuid, p_permanent boolean) -> jsonb
-- Users remain; all match-scoped data is removed; the pair's future
-- matchability follows p_permanent (see header).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_delete_match(
  p_match_id uuid,
  p_permanent boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin   boolean;
  v_user1      uuid;
  v_user2      uuid;
  v_match_type text;
  v_rec        record;
  v_schema     text;
  v_table      text;
  v_msg_count  int := 0;
  v_a          uuid;
  v_b          uuid;
  v_admin_id   uuid;
  v_permanent  boolean;
BEGIN
  IF auth.role() = 'service_role' THEN
    v_is_admin := true;
  ELSE
    SELECT EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.is_admin = true
    ) INTO v_is_admin;
  END IF;
  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_match_id IS NULL THEN
    RAISE EXCEPTION 'p_match_id is required';
  END IF;
  v_permanent := COALESCE(p_permanent, false);

  SELECT m.user1_id, m.user2_id, m.match_type INTO v_user1, v_user2, v_match_type
    FROM public.matches m WHERE m.id = p_match_id;
  IF v_user1 IS NULL OR v_user2 IS NULL THEN
    RAISE EXCEPTION 'match not found';
  END IF;

  v_a := LEAST(v_user1, v_user2);
  v_b := GREATEST(v_user1, v_user2);

  IF to_regclass('public.chat_messages') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='chat_messages'
                   AND column_name='match_id') THEN
    SELECT count(*)::int INTO v_msg_count
      FROM public.chat_messages WHERE match_id = p_match_id;
  END IF;

  -- message_reactions for this match's messages FIRST (before messages,
  -- in case the FK has no cascade in some environments).
  IF to_regclass('public.message_reactions') IS NOT NULL
     AND to_regclass('public.chat_messages') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='message_reactions'
                   AND column_name='message_id') THEN
    DELETE FROM public.message_reactions mr
     WHERE mr.message_id IN (SELECT cm.id FROM public.chat_messages cm
                             WHERE cm.match_id = p_match_id);
  END IF;

  -- All per-match tables (incl. stale unmatched_pairs refs to this match).
  FOR v_rec IN SELECT * FROM (VALUES
    ('public.chat_messages',        'match_id'),
    ('public.chats',                'match_id'),
    ('public.chat_rooms',           'match_id'),
    ('public.user_recent_chats',    'match_id'),
    ('public.user_recent_matches',  'match_id'),
    ('public.match_ratings',        'match_id'),
    ('public.match_rating_prompts', 'match_id'),
    ('public.pending_rating_prompts','match_id'),
    ('public.match_chat_extensions','match_id'),
    ('public.match_expiry_warnings','match_id'),
    ('public.unmatched_pairs',      'match_id')
  ) AS t(tbl, col)
  LOOP
    IF to_regclass(v_rec.tbl) IS NULL THEN CONTINUE; END IF;
    v_schema := split_part(v_rec.tbl, '.', 1);
    v_table  := split_part(v_rec.tbl, '.', 2);
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema=v_schema AND table_name=v_table
                     AND column_name=v_rec.col) THEN CONTINUE; END IF;
    EXECUTE format('DELETE FROM %I.%I WHERE %I = $1', v_schema, v_table, v_rec.col)
      USING p_match_id;
  END LOOP;

  -- Finally the match row itself
  DELETE FROM public.matches WHERE id = p_match_id;

  -- -- Pair future-matchability (ordered pair v_a < v_b) --
  IF to_regclass('public.unmatched_pairs') IS NOT NULL THEN
    IF v_permanent THEN
      -- PERMANENT: block every future match of this pair.
      v_admin_id := COALESCE(
        auth.uid(),
        '00000000-0000-0000-0000-000000000000'::uuid
      );
      IF EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='unmatched_pairs'
                   AND column_name='is_permanent')
         AND EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='unmatched_pairs'
                   AND column_name='expiry_count') THEN
        INSERT INTO public.unmatched_pairs
          (user1_id, user2_id, created_by, created_at,
           match_type, match_id, expiry_count, is_permanent)
        VALUES
          (v_a, v_b, v_admin_id, now(),
           v_match_type, p_match_id,
           COALESCE((SELECT up.expiry_count FROM public.unmatched_pairs up
                     WHERE up.user1_id = v_a AND up.user2_id = v_b), 0),
           true)
        ON CONFLICT (user1_id, user2_id) DO UPDATE SET
          created_by   = EXCLUDED.created_by,
          created_at   = GREATEST(unmatched_pairs.created_at, EXCLUDED.created_at),
          match_type   = COALESCE(unmatched_pairs.match_type, EXCLUDED.match_type),
          match_id     = COALESCE(unmatched_pairs.match_id, EXCLUDED.match_id),
          is_permanent = true;
      ELSE
        -- Legacy schema without expiry columns: the row's mere presence
        -- blocks rematching in the older engines.
        INSERT INTO public.unmatched_pairs
          (user1_id, user2_id, created_by, created_at, match_type, match_id)
        VALUES
          (v_a, v_b, v_admin_id, now(), v_match_type, p_match_id)
        ON CONFLICT (user1_id, user2_id) DO UPDATE SET
          created_by = EXCLUDED.created_by,
          created_at = GREATEST(unmatched_pairs.created_at, EXCLUDED.created_at),
          match_type = COALESCE(unmatched_pairs.match_type, EXCLUDED.match_type),
          match_id   = COALESCE(unmatched_pairs.match_id, EXCLUDED.match_id);
      END IF;
    ELSE
      -- REMATCH-ELIGIBLE: clean slate - remove any block for this pair so
      -- the matching engine may pair them again (next match = occurrence 1).
      DELETE FROM public.unmatched_pairs up
       WHERE up.user1_id = v_a AND up.user2_id = v_b;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'deleted_match_id', p_match_id,
    'user1_id', v_user1,
    'user2_id', v_user2,
    'deleted_messages', v_msg_count,
    'permanent', v_permanent
  );
END;
$$;

-- ============================================================================
-- Grants (Admin app authenticates as `authenticated` via user JWT)
-- ============================================================================
GRANT EXECUTE ON FUNCTION public.admin_delete_match(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_match(uuid, boolean) TO service_role;

-- ============================================================================
-- Translations (EN / ES / HE) for the rematch-choice UI.
-- ============================================================================
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminDeleteMatchOptionRematch', 'Allow future rematch'),
  ('es', 'adminDeleteMatchOptionRematch', 'Permitir futura coincidencia'),
  ('he', 'adminDeleteMatchOptionRematch', 'לאפשר התאמה עתידית'),

  ('en', 'adminDeleteMatchOptionRematchDesc', 'The system may match these users again.'),
  ('es', 'adminDeleteMatchOptionRematchDesc', 'El sistema podrá volver a emparejar a estos usuarios.'),
  ('he', 'adminDeleteMatchOptionRematchDesc', 'המערכת תוכל להתאים בין המשתמשים שוב.'),

  ('en', 'adminDeleteMatchOptionPermanent', 'Never match again'),
  ('es', 'adminDeleteMatchOptionPermanent', 'No volver a emparejar'),
  ('he', 'adminDeleteMatchOptionPermanent', 'לא להתאים שוב לעולם'),

  ('en', 'adminDeleteMatchOptionPermanentDesc', 'These users will never be matched again.'),
  ('es', 'adminDeleteMatchOptionPermanentDesc', 'Estos usuarios nunca volverán a ser emparejados.'),
  ('he', 'adminDeleteMatchOptionPermanentDesc', 'המשתמשים האלה לעולם לא יותאמו שוב.'),

  ('en', 'adminDeleteMatchSuccessPermanent', 'Match deleted. The users will never be matched again.'),
  ('es', 'adminDeleteMatchSuccessPermanent', 'Coincidencia eliminada. Los usuarios nunca volverán a ser emparejados.'),
  ('he', 'adminDeleteMatchSuccessPermanent', 'ההתאמה נמחקה. המשתמשים לעולם לא יותאמו שוב.'),

  ('en', 'adminUserMatchLabelMatchId', 'Match ID'),
  ('es', 'adminUserMatchLabelMatchId', 'ID de coincidencia'),
  ('he', 'adminUserMatchLabelMatchId', 'מזהה התאמה'),

  ('en', 'adminUserMatchLabelType', 'Type'),
  ('es', 'adminUserMatchLabelType', 'Tipo'),
  ('he', 'adminUserMatchLabelType', 'סוג')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
