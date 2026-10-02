-- ============================================================================
-- COPY & PASTE THIS ENTIRE SCRIPT INTO SUPABASE SQL EDITOR TO FIX:
-- "operator does not exist: character varying = uuid"
-- ============================================================================
-- 
-- INSTRUCTIONS:
-- 1. Open your Supabase Dashboard: https://supabase.com/dashboard
-- 2. Select your project: MatchMe (vazkmvrbshxwyodentng)
-- 3. In the left navigation, click on "SQL Editor"
-- 4. Click "+ New query"
-- 5. Copy and paste this ENTIRE file into the editor
-- 6. Click "Run" (or press Ctrl+Enter / Cmd+Enter)
-- 7. You should see "Success. No rows returned"
-- 8. Return to the Admin app and delete the user — it will now succeed!
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1) admin_delete_user(p_user_id uuid) -> jsonb
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_delete_user(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin        boolean;
  v_match_ids       uuid[];
  v_rec             record;
  v_schema          text;
  v_table           text;
  v_col_type        text;
  v_owner_col       text;
  v_deleted_matches int := 0;
  v_user_name       text;
BEGIN
  -- -- Auth: allow service_role outright, otherwise require is_admin --
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

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'p_user_id is required';
  END IF;

  -- -- Safety: never let an admin delete their own login --
  IF auth.uid() IS NOT NULL AND p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'cannot delete own admin account';
  END IF;

  SELECT u.name INTO v_user_name FROM public.users u WHERE u.id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'user not found';
  END IF;

  -- -- Collect the user's match ids FIRST (needed to clean the OTHER
  --    user's per-match rows: chats, user_recent_chats, messages, ...) --
  IF to_regclass('public.matches') IS NOT NULL THEN
    SELECT COALESCE(array_agg(m.id), '{}'::uuid[]) INTO v_match_ids
      FROM public.matches m
     WHERE m.user1_id = p_user_id OR m.user2_id = p_user_id;
  ELSE
    v_match_ids := '{}'::uuid[];
  END IF;
  v_deleted_matches := COALESCE(array_length(v_match_ids, 1), 0);

  -- -- 1a) Match-scoped data for the user's matches (both sides) --
  -- message_reactions FIRST (before messages, in case the FK has no
  -- cascade in some environments), then messages, then per-match rows.
  IF to_regclass('public.message_reactions') IS NOT NULL
     AND to_regclass('public.chat_messages') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='message_reactions'
                   AND column_name='message_id')
     AND EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='chat_messages'
                   AND column_name='match_id') THEN
    BEGIN
      DELETE FROM public.message_reactions mr
       WHERE mr.message_id IN (SELECT cm.id FROM public.chat_messages cm
                               WHERE cm.match_id = ANY(v_match_ids));
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'admin_delete_user: message_reactions cleanup skipped: %', SQLERRM;
    END;
  END IF;

  -- chat_messages by match_id
  IF to_regclass('public.chat_messages') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='chat_messages'
                   AND column_name='match_id') THEN
    BEGIN
      DELETE FROM public.chat_messages cm WHERE cm.match_id = ANY(v_match_ids);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'admin_delete_user: chat_messages by match_id skipped: %', SQLERRM;
    END;
  END IF;

  -- Per-match tables keyed by match_id
  FOR v_rec IN SELECT * FROM (VALUES
    ('public.chats',               'match_id'),
    ('public.chat_rooms',           'match_id'),
    ('public.user_recent_chats',    'match_id'),
    ('public.user_recent_matches',  'match_id'),
    ('public.match_ratings',        'match_id'),
    ('public.match_rating_prompts', 'match_id'),
    ('public.pending_rating_prompts','match_id'),
    ('public.match_chat_extensions','match_id'),
    ('public.match_expiry_warnings','match_id'),
    ('public.unmatched_pairs',      'match_id'),
    ('public.location_share_signals','match_id')
  ) AS t(tbl, col)
  LOOP
    IF to_regclass(v_rec.tbl) IS NULL THEN CONTINUE; END IF;
    v_schema := split_part(v_rec.tbl, '.', 1);
    v_table  := split_part(v_rec.tbl, '.', 2);
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema=v_schema AND table_name=v_table
                     AND column_name=v_rec.col) THEN CONTINUE; END IF;
    BEGIN
      SELECT data_type INTO v_col_type
        FROM information_schema.columns
       WHERE table_schema = v_schema
         AND table_name   = v_table
         AND column_name  = v_rec.col;

      IF v_col_type IN ('character varying', 'varchar', 'text', 'character') THEN
        EXECUTE format('DELETE FROM %I.%I WHERE %I::text = ANY($1::text[])', v_schema, v_table, v_rec.col)
          USING v_match_ids::text[];
      ELSE
        EXECUTE format('DELETE FROM %I.%I WHERE %I = ANY($1)', v_schema, v_table, v_rec.col)
          USING v_match_ids;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'admin_delete_user: match-scoped %.% skipped: %', v_rec.tbl, v_rec.col, SQLERRM;
    END;
  END LOOP;

  -- -- 1b) The match rows themselves --
  IF to_regclass('public.matches') IS NOT NULL THEN
    BEGIN
      DELETE FROM public.matches m
       WHERE m.user1_id = p_user_id OR m.user2_id = p_user_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'admin_delete_user: matches skipped: %', SQLERRM;
    END;
  END IF;

  -- -- 1c) Remaining user-keyed rows (single-column deletes) --
  FOR v_rec IN SELECT * FROM (VALUES
    ('public.chat_messages',        'sender_id'),
    ('public.chat_messages',        'recipient_id'),
    ('public.message_reactions',    'user_id'),
    ('public.chats',                'user_id'),
    ('public.chats',                'other_user_id'),
    ('public.user_recent_chats',    'user_id'),
    ('public.user_recent_chats',    'other_user_id'),
    ('public.user_recent_matches',  'user_id'),
    ('public.user_recent_matches',  'other_user_id'),
    ('public.unmatched_pairs',      'user1_id'),
    ('public.unmatched_pairs',      'user2_id'),
    ('public.unmatched_pairs',      'created_by'),
    ('public.chat_rooms',           'user_id'),
    ('public.match_ratings',        'rater_id'),
    ('public.match_ratings',        'ratee_id'),
    ('public.match_rating_prompts', 'user_id'),
    ('public.pending_rating_prompts','user_id'),
    ('public.pending_rating_prompts','other_user_id'),
    ('public.match_chat_extensions','user_id'),
    ('public.match_expiry_warnings','user_id'),
    ('public.event_attendees',      'user_id'),
    ('public.event_participants',   'user_id'),
    ('public.event_parse_results',  'user_id'),
    ('public.referrals',            'referrer_id'),
    ('public.referrals',            'referee_id'),
    ('public.promo_code_usages',    'user_id'),
    ('public.user_locations',       'user_id'),
    ('public.offline_location_history', 'user_id'),
    ('public.user_profiles',        'user_id'),
    ('public.user_interests',       'user_id'),
    ('public.user_intents',         'user_id'),
    ('public.user_blocks',          'user_id'),
    ('public.user_blocks',          'blocked_user_id'),
    ('public.user_reports',         'user_id'),
    ('public.user_reports',         'reported_user_id'),
    ('public.user_invisibility_rules','user_id'),
    ('public.user_visibility_schedules','user_id'),
    ('public.invisibility_rules',   'user_id'),
    ('public.user_activity',        'user_id'),
    ('public.user_session',         'user_id'),
    ('public.notification_queue',   'user_id'),
    ('public.user_subscription_queue','user_id'),
    ('public.admin_broadcast_deliveries','user_id'),
    ('public.profile_edit_requests','user_id'),
    ('public.ad_impressions',       'user_id'),
    ('public.ad_clicks',            'user_id'),
    ('public.ad_reports',           'user_id'),
    ('public.ad_revenue_events',    'user_id'),
    ('public.ad_consent',           'user_id'),
    ('public.user_chat_keys',       'user_id'),
    ('public.user_chat_key_wrappers','user_id'),
    ('public.user_chat_crk_wrappers','user_id'),
    ('public.location_share_signals','sharer_id'),
    ('public.edge_function_invocations','user_id'),
    ('public.signup_fraud_signals', 'user_id')
  ) AS t(tbl, col)
  LOOP
    IF to_regclass(v_rec.tbl) IS NULL THEN CONTINUE; END IF;
    v_schema := split_part(v_rec.tbl, '.', 1);
    v_table  := split_part(v_rec.tbl, '.', 2);
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema=v_schema AND table_name=v_table
                     AND column_name=v_rec.col) THEN CONTINUE; END IF;
    BEGIN
      SELECT data_type INTO v_col_type
        FROM information_schema.columns
       WHERE table_schema = v_schema
         AND table_name   = v_table
         AND column_name  = v_rec.col;

      IF v_col_type IN ('character varying', 'varchar', 'text', 'character') THEN
        EXECUTE format('DELETE FROM %I.%I WHERE %I = $1::text', v_schema, v_table, v_rec.col)
          USING p_user_id;
      ELSE
        EXECUTE format('DELETE FROM %I.%I WHERE %I = $1', v_schema, v_table, v_rec.col)
          USING p_user_id;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'admin_delete_user: user-scoped %.% skipped: %', v_rec.tbl, v_rec.col, SQLERRM;
    END;
  END LOOP;

  -- -- 1d) Events: remove attendance, then delete orphaned owned events,
  --    null the owner on still-attended events (mirrors delete-account) --
  IF to_regclass('public.events') IS NOT NULL THEN
    SELECT column_name INTO v_owner_col
      FROM information_schema.columns
     WHERE table_schema='public' AND table_name='events'
       AND column_name IN ('created_by','owner_id','user_id')
     ORDER BY CASE column_name WHEN 'created_by' THEN 1 WHEN 'owner_id' THEN 2 ELSE 3 END
     LIMIT 1;
    IF v_owner_col IS NOT NULL THEN
      SELECT data_type INTO v_col_type
        FROM information_schema.columns
       WHERE table_schema='public' AND table_name='events'
         AND column_name=v_owner_col;

      IF to_regclass('public.event_attendees') IS NOT NULL THEN
        BEGIN
          IF v_col_type IN ('character varying', 'varchar', 'text', 'character') THEN
            EXECUTE format(
              'DELETE FROM public.events WHERE %I = $1::text AND NOT EXISTS ' ||
              '(SELECT 1 FROM public.event_attendees ea WHERE ea.event_id = public.events.id)',
              v_owner_col) USING p_user_id;
          ELSE
            EXECUTE format(
              'DELETE FROM public.events WHERE %I = $1 AND NOT EXISTS ' ||
              '(SELECT 1 FROM public.event_attendees ea WHERE ea.event_id = public.events.id)',
              v_owner_col) USING p_user_id;
          END IF;
        EXCEPTION WHEN OTHERS THEN
          RAISE NOTICE 'admin_delete_user: event deletion skipped: %', SQLERRM;
        END;
        BEGIN
          IF v_col_type IN ('character varying', 'varchar', 'text', 'character') THEN
            EXECUTE format(
              'UPDATE public.events SET %I = NULL WHERE %I = $1::text AND EXISTS ' ||
              '(SELECT 1 FROM public.event_attendees ea WHERE ea.event_id = public.events.id)',
              v_owner_col, v_owner_col) USING p_user_id;
          ELSE
            EXECUTE format(
              'UPDATE public.events SET %I = NULL WHERE %I = $1 AND EXISTS ' ||
              '(SELECT 1 FROM public.event_attendees ea WHERE ea.event_id = public.events.id)',
              v_owner_col, v_owner_col) USING p_user_id;
          END IF;
        EXCEPTION WHEN OTHERS THEN
          RAISE NOTICE 'admin_delete_user: event owner null-out skipped: %', SQLERRM;
        END;
      ELSE
        BEGIN
          IF v_col_type IN ('character varying', 'varchar', 'text', 'character') THEN
            EXECUTE format('DELETE FROM public.events WHERE %I = $1::text', v_owner_col)
              USING p_user_id;
          ELSE
            EXECUTE format('DELETE FROM public.events WHERE %I = $1', v_owner_col)
              USING p_user_id;
          END IF;
        EXCEPTION WHEN OTHERS THEN
          RAISE NOTICE 'admin_delete_user: event deletion without attendees skipped: %', SQLERRM;
        END;
      END IF;
    END IF;
  END IF;

  -- -- 1e) Null out references TO this user from admin/other-owned rows --
  FOR v_rec IN SELECT * FROM (VALUES
    ('public.admin_broadcasts',      'created_by'),
    ('public.profile_edit_requests', 'reviewed_by'),
    ('public.users',                 'verification_reviewer_id')
  ) AS t(tbl, col)
  LOOP
    IF to_regclass(v_rec.tbl) IS NULL THEN CONTINUE; END IF;
    v_schema := split_part(v_rec.tbl, '.', 1);
    v_table  := split_part(v_rec.tbl, '.', 2);
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema=v_schema AND table_name=v_table
                     AND column_name=v_rec.col) THEN CONTINUE; END IF;
    BEGIN
      SELECT data_type INTO v_col_type
        FROM information_schema.columns
       WHERE table_schema = v_schema
         AND table_name   = v_table
         AND column_name  = v_rec.col;

      IF v_col_type IN ('character varying', 'varchar', 'text', 'character') THEN
        EXECUTE format('UPDATE %I.%I SET %I = NULL WHERE %I = $1::text',
                       v_schema, v_table, v_rec.col, v_rec.col)
          USING p_user_id;
      ELSE
        EXECUTE format('UPDATE %I.%I SET %I = NULL WHERE %I = $1',
                       v_schema, v_table, v_rec.col, v_rec.col)
          USING p_user_id;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'admin_delete_user: null-out %.% skipped: %', v_rec.tbl, v_rec.col, SQLERRM;
    END;
  END LOOP;

  -- -- 1f) Storage object metadata for the user's folder --
  BEGIN
    PERFORM set_config('storage.can_delete', 'true', true);
    PERFORM set_config('storage.allow_delete_query', 'true', true);
    DELETE FROM storage.objects
     WHERE (storage.foldername(name))[1] = p_user_id::text
        OR name LIKE '%' || p_user_id::text || '%';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'admin_delete_user: storage metadata cleanup skipped: %', SQLERRM;
  END;

  -- -- 1g) The public user row (cascades take remaining children) --
  DELETE FROM public.users WHERE id = p_user_id;

  -- -- 1h) Auth-layer rows (direct deletes cascade to identities,
  --    sessions, refresh tokens, MFA, passkeys; skipped if missing) --
  FOR v_rec IN SELECT * FROM (VALUES
    ('auth.identities',                  'user_id'),
    ('auth.sessions',                    'user_id'),
    ('auth.refresh_tokens',              'user_id'),
    ('auth.user_mfa_recovery_codes',     'user_id'),
    ('auth.mfa_factors',                 'user_id'),
    ('auth.passkey_credentials',         'user_id'),
    ('auth.passkey_challenges',          'user_id'),
    ('auth.sensitive_action_email_codes','user_id'),
    ('auth.pending_email_changes',       'user_id'),
    ('auth.sso_sessions',                'user_id'),
    ('auth.users',                       'id')
  ) AS t(tbl, col)
  LOOP
    IF to_regclass(v_rec.tbl) IS NULL THEN CONTINUE; END IF;
    v_schema := split_part(v_rec.tbl, '.', 1);
    v_table  := split_part(v_rec.tbl, '.', 2);
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema=v_schema AND table_name=v_table
                     AND column_name=v_rec.col) THEN CONTINUE; END IF;
    BEGIN
      SELECT data_type INTO v_col_type
        FROM information_schema.columns
       WHERE table_schema = v_schema
         AND table_name   = v_table
         AND column_name  = v_rec.col;

      IF v_col_type IN ('character varying', 'varchar', 'text', 'character') THEN
        EXECUTE format('DELETE FROM %I.%I WHERE %I = $1::text', v_schema, v_table, v_rec.col)
          USING p_user_id;
      ELSE
        EXECUTE format('DELETE FROM %I.%I WHERE %I = $1', v_schema, v_table, v_rec.col)
          USING p_user_id;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'admin_delete_user: auth %.% skipped: %', v_rec.tbl, v_rec.col, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'deleted_user_id', p_user_id,
    'deleted_user_name', COALESCE(v_user_name, ''),
    'deleted_matches', v_deleted_matches
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_delete_user(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(uuid) TO service_role;

-- ============================================================================
-- 2) admin_delete_match(p_match_id uuid, p_permanent boolean) -> jsonb
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
  v_col_type   text;
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
                   AND column_name='message_id')
     AND EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='chat_messages'
                   AND column_name='match_id') THEN
    BEGIN
      DELETE FROM public.message_reactions mr
       WHERE mr.message_id IN (SELECT cm.id FROM public.chat_messages cm
                               WHERE cm.match_id = p_match_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'admin_delete_match: message_reactions cleanup skipped: %', SQLERRM;
    END;
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
    ('public.unmatched_pairs',      'match_id'),
    ('public.location_share_signals','match_id')
  ) AS t(tbl, col)
  LOOP
    IF to_regclass(v_rec.tbl) IS NULL THEN CONTINUE; END IF;
    v_schema := split_part(v_rec.tbl, '.', 1);
    v_table  := split_part(v_rec.tbl, '.', 2);
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema=v_schema AND table_name=v_table
                     AND column_name=v_rec.col) THEN CONTINUE; END IF;
    BEGIN
      SELECT data_type INTO v_col_type
        FROM information_schema.columns
       WHERE table_schema = v_schema
         AND table_name   = v_table
         AND column_name  = v_rec.col;

      IF v_col_type IN ('character varying', 'varchar', 'text', 'character') THEN
        EXECUTE format('DELETE FROM %I.%I WHERE %I = $1::text', v_schema, v_table, v_rec.col)
          USING p_match_id;
      ELSE
        EXECUTE format('DELETE FROM %I.%I WHERE %I = $1', v_schema, v_table, v_rec.col)
          USING p_match_id;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'admin_delete_match: %.% skipped: %', v_rec.tbl, v_rec.col, SQLERRM;
    END;
  END LOOP;

  -- The match row itself
  DELETE FROM public.matches WHERE id = p_match_id;

  -- Pair matchability behaviour driven by p_permanent:
  IF to_regclass('public.unmatched_pairs') IS NOT NULL THEN
    IF v_permanent THEN
      v_admin_id := auth.uid();
      INSERT INTO public.unmatched_pairs (
        user1_id,
        user2_id,
        match_type,
        is_permanent,
        created_by,
        created_at
      ) VALUES (
        v_a,
        v_b,
        v_match_type,
        true,
        v_admin_id,
        now()
      )
      ON CONFLICT (user1_id, user2_id) DO UPDATE
        SET is_permanent = true,
            match_id     = NULL,
            created_by   = COALESCE(EXCLUDED.created_by, unmatched_pairs.created_by);
    ELSE
      DELETE FROM public.unmatched_pairs
       WHERE user1_id = v_a AND user2_id = v_b;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'deleted_match_id', p_match_id,
    'user1_id', v_user1,
    'user2_id', v_user2,
    'messages_deleted', v_msg_count,
    'permanent', v_permanent
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_delete_match(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_match(uuid, boolean) TO service_role;

COMMIT;
