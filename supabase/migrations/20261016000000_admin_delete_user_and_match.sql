-- Migration: Admin delete user + delete match (with match search)
-- Purpose:
--   Give the Admin app an easy, confirmed way to:
--     1. Completely delete a USER (all related data: matches, chats,
--        messages, ratings, events attendance, referrals, profile data,
--        activity, ads, encryption keys, storage metadata, public.users
--        row and the auth.users row).
--     2. Completely delete a MATCH (users remain; all match-scoped data:
--        messages, chats rows for both users, ratings, prompts, extensions,
--        warnings, unmatched_pairs refs, and the match row itself).
--   Both RPCs are SECURITY DEFINER, verify the caller is an admin
--   (public.users.is_admin), and are granted to `authenticated` so the
--   Admin Flutter app (anon key + user JWT) can call them.
--
--   Also adds admin_search_matches() so the admin can find ANY match by
--   match ID, user name, or user ID (dashboard drilldowns only show
--   recent-window matches).
--
-- Safety:
--   - Every delete checks to_regclass() + information_schema so missing
--     tables/columns are skipped (idempotent, safe to rerun).
--   - admin_delete_user refuses to delete the caller's own admin account.
--   - Events created by the user are deleted ONLY when no other user
--     attends them; otherwise the owner column is nulled (same rule as
--     the delete-account edge function).
--   - Storage: deletes storage.objects metadata rows for the user's
--     folder (sets the documented session flags to bypass the
--     protect_delete trigger). File BYTES in the object store must be
--     removed via the Storage API / Dashboard for a byte-level wipe
--     (same limitation as delete_user_complete.sql).
--
-- Usage (after applying):
--   SELECT public.admin_delete_user('<user-uuid>');
--   SELECT public.admin_delete_match('<match-uuid>');
--   SELECT * FROM public.admin_search_matches('query', 20);

BEGIN;

-- ============================================================================
-- 0) Admin check helper (shared pattern, no new table)
-- ============================================================================
-- (Inlined in each function to avoid extra public helpers.)

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
  v_is_admin   boolean;
  v_match_ids  uuid[];
  v_rec        record;
  v_schema     text;
  v_table      text;
  v_owner_col  text;
  v_deleted_matches int := 0;
  v_user_name  text;
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
    DELETE FROM public.message_reactions mr
     WHERE mr.message_id IN (SELECT cm.id FROM public.chat_messages cm
                             WHERE cm.match_id = ANY(v_match_ids));
  END IF;

  -- chat_messages by match_id
  IF to_regclass('public.chat_messages') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='chat_messages'
                   AND column_name='match_id') THEN
    DELETE FROM public.chat_messages cm WHERE cm.match_id = ANY(v_match_ids);
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
    ('public.unmatched_pairs',      'match_id')
  ) AS t(tbl, col)
  LOOP
    IF to_regclass(v_rec.tbl) IS NULL THEN CONTINUE; END IF;
    v_schema := split_part(v_rec.tbl, '.', 1);
    v_table  := split_part(v_rec.tbl, '.', 2);
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema=v_schema AND table_name=v_table
                     AND column_name=v_rec.col) THEN CONTINUE; END IF;
    EXECUTE format('DELETE FROM %I.%I WHERE %I = ANY($1)', v_schema, v_table, v_rec.col)
      USING v_match_ids;
  END LOOP;

  -- -- 1b) The match rows themselves --
  IF to_regclass('public.matches') IS NOT NULL THEN
    DELETE FROM public.matches m
     WHERE m.user1_id = p_user_id OR m.user2_id = p_user_id;
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
    EXECUTE format('DELETE FROM %I.%I WHERE %I = $1', v_schema, v_table, v_rec.col)
      USING p_user_id;
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
      IF to_regclass('public.event_attendees') IS NOT NULL THEN
        BEGIN
          EXECUTE format(
            'DELETE FROM public.events WHERE %I = $1 AND NOT EXISTS ' ||
            '(SELECT 1 FROM public.event_attendees ea WHERE ea.event_id = public.events.id)',
            v_owner_col) USING p_user_id;
        EXCEPTION WHEN OTHERS THEN
          RAISE NOTICE 'admin_delete_user: event deletion skipped: %', SQLERRM;
        END;
        BEGIN
          EXECUTE format(
            'UPDATE public.events SET %I = NULL WHERE %I = $1 AND EXISTS ' ||
            '(SELECT 1 FROM public.event_attendees ea WHERE ea.event_id = public.events.id)',
            v_owner_col, v_owner_col) USING p_user_id;
        EXCEPTION WHEN OTHERS THEN
          RAISE NOTICE 'admin_delete_user: event owner null-out skipped: %', SQLERRM;
        END;
      ELSE
        EXECUTE format('DELETE FROM public.events WHERE %I = $1', v_owner_col)
          USING p_user_id;
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
      EXECUTE format('UPDATE %I.%I SET %I = NULL WHERE %I = $1',
                     v_schema, v_table, v_rec.col, v_rec.col)
        USING p_user_id;
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
    EXECUTE format('DELETE FROM %I.%I WHERE %I = $1', v_schema, v_table, v_rec.col)
      USING p_user_id;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'deleted_user_id', p_user_id,
    'deleted_user_name', COALESCE(v_user_name, ''),
    'deleted_matches', v_deleted_matches
  );
END;
$$;

-- ============================================================================
-- 2) admin_delete_match(p_match_id uuid) -> jsonb
--    Users remain; all match-scoped data is removed.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_delete_match(p_match_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin   boolean;
  v_user1      uuid;
  v_user2      uuid;
  v_rec        record;
  v_schema     text;
  v_table      text;
  v_msg_count  int := 0;
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

  SELECT m.user1_id, m.user2_id INTO v_user1, v_user2
    FROM public.matches m WHERE m.id = p_match_id;
  IF v_user1 IS NULL OR v_user2 IS NULL THEN
    RAISE EXCEPTION 'match not found';
  END IF;

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

  -- All per-match tables
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

  RETURN jsonb_build_object(
    'success', true,
    'deleted_match_id', p_match_id,
    'user1_id', v_user1,
    'user2_id', v_user2,
    'deleted_messages', v_msg_count
  );
END;
$$;

-- ============================================================================
-- 3) admin_search_matches(p_query text, p_limit int) -> recent/global search
--    Lets the admin find ANY match (not only the dashboard window) by
--    match ID, user ID, or user name.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_search_matches(
  p_query text DEFAULT NULL,
  p_limit integer DEFAULT 20
)
RETURNS TABLE (
  match_id uuid,
  user1_id uuid,
  user1_name text,
  user2_id uuid,
  user2_name text,
  match_type text,
  matched_intent text,
  message_count bigint,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_query    text;
  v_limit    int;
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

  v_query := NULLIF(trim(COALESCE(p_query, '')), '');
  v_limit := GREATEST(LEAST(COALESCE(p_limit, 20), 100), 1);

  RETURN QUERY
  SELECT
    m.id AS match_id,
    m.user1_id,
    COALESCE(u1.name, '') AS user1_name,
    m.user2_id,
    COALESCE(u2.name, '') AS user2_name,
    m.match_type,
    m.matched_intent,
    COALESCE((SELECT count(*) FROM public.chat_messages cm
              WHERE cm.match_id = m.id), 0) AS message_count,
    m.created_at
  FROM public.matches m
  LEFT JOIN public.users u1 ON u1.id = m.user1_id
  LEFT JOIN public.users u2 ON u2.id = m.user2_id
  WHERE v_query IS NULL
     OR m.id::text ILIKE '%' || v_query || '%'
     OR m.user1_id::text ILIKE '%' || v_query || '%'
     OR m.user2_id::text ILIKE '%' || v_query || '%'
     OR COALESCE(u1.name, '') ILIKE '%' || v_query || '%'
     OR COALESCE(u2.name, '') ILIKE '%' || v_query || '%'
  ORDER BY m.created_at DESC, m.id DESC
  LIMIT v_limit;
END;
$$;

-- ============================================================================
-- 4) Grants (Admin app authenticates as `authenticated` via user JWT)
-- ============================================================================
GRANT EXECUTE ON FUNCTION public.admin_delete_user(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_match(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_match(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_search_matches(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_search_matches(text, integer) TO service_role;

-- ============================================================================
-- 5) Translations (EN / ES / HE) for the new Admin delete screens.
--    Admin app reads these via the translations table (public-reference-data
--    edge function); Dart _defaultTranslations holds the English fallback.
-- ============================================================================
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminNavUserMatchManagement', 'Users & Matches'),
  ('es', 'adminNavUserMatchManagement', 'Usuarios y coincidencias'),
  ('he', 'adminNavUserMatchManagement', 'משתמשים והתאמות'),

  ('en', 'adminUserMatchTabUsers', 'Users'),
  ('es', 'adminUserMatchTabUsers', 'Usuarios'),
  ('he', 'adminUserMatchTabUsers', 'משתמשים'),

  ('en', 'adminUserMatchTabMatches', 'Matches'),
  ('es', 'adminUserMatchTabMatches', 'Coincidencias'),
  ('he', 'adminUserMatchTabMatches', 'התאמות'),

  ('en', 'adminUserMatchSearchUsersHint', 'Search by name, email, or user ID...'),
  ('es', 'adminUserMatchSearchUsersHint', 'Buscar por nombre, correo o ID de usuario...'),
  ('he', 'adminUserMatchSearchUsersHint', 'חיפוש לפי שם, אימייל או מזהה משתמש...'),

  ('en', 'adminUserMatchSearchMatchesHint', 'Search by match ID, user name, or user ID...'),
  ('es', 'adminUserMatchSearchMatchesHint', 'Buscar por ID de coincidencia, nombre o ID de usuario...'),
  ('he', 'adminUserMatchSearchMatchesHint', 'חיפוש לפי מזהה התאמה, שם משתמש או מזהה משתמש...'),

  ('en', 'adminDeleteUserConfirmTitle', 'Delete user?'),
  ('es', 'adminDeleteUserConfirmTitle', '¿Eliminar usuario?'),
  ('he', 'adminDeleteUserConfirmTitle', 'למחוק משתמש?'),

  ('en', 'adminDeleteUserConfirmBody', 'Permanently delete {name} and ALL related data (matches, chats, messages, photos, and settings)? This cannot be undone.'),
  ('es', 'adminDeleteUserConfirmBody', '¿Eliminar permanentemente a {name} y TODOS sus datos relacionados (coincidencias, chats, mensajes, fotos y ajustes)? Esta acción no se puede deshacer.'),
  ('he', 'adminDeleteUserConfirmBody', 'למחוק לצמיתות את {name} ואת כל הנתונים הקשורים (התאמות, צ׳אטים, הודעות, תמונות והגדרות)? לא ניתן לבטל פעולה זו.'),

  ('en', 'adminDeleteMatchConfirmTitle', 'Delete match?'),
  ('es', 'adminDeleteMatchConfirmTitle', '¿Eliminar coincidencia?'),
  ('he', 'adminDeleteMatchConfirmTitle', 'למחוק התאמה?'),

  ('en', 'adminDeleteMatchConfirmBody', 'Permanently delete this match ({info}) and ALL related data (chats, messages, ratings)? The users will remain. This cannot be undone.'),
  ('es', 'adminDeleteMatchConfirmBody', '¿Eliminar permanentemente esta coincidencia ({info}) y TODOS sus datos relacionados (chats, mensajes, valoraciones)? Los usuarios se conservarán. Esta acción no se puede deshacer.'),
  ('he', 'adminDeleteMatchConfirmBody', 'למחוק לצמיתות את ההתאמה ({info}) ואת כל הנתונים הקשורים (צ׳אטים, הודעות, דירוגים)? המשתמשים יישארו. לא ניתן לבטל פעולה זו.'),

  ('en', 'adminDeleteUserSuccess', 'User deleted.'),
  ('es', 'adminDeleteUserSuccess', 'Usuario eliminado.'),
  ('he', 'adminDeleteUserSuccess', 'המשתמש נמחק.'),

  ('en', 'adminDeleteUserFailed', 'Failed to delete user: {error}'),
  ('es', 'adminDeleteUserFailed', 'No se pudo eliminar el usuario: {error}'),
  ('he', 'adminDeleteUserFailed', 'מחיקת המשתמש נכשלה: {error}'),

  ('en', 'adminDeleteMatchSuccess', 'Match deleted.'),
  ('es', 'adminDeleteMatchSuccess', 'Coincidencia eliminada.'),
  ('he', 'adminDeleteMatchSuccess', 'ההתאמה נמחקה.'),

  ('en', 'adminDeleteMatchFailed', 'Failed to delete match: {error}'),
  ('es', 'adminDeleteMatchFailed', 'No se pudo eliminar la coincidencia: {error}'),
  ('he', 'adminDeleteMatchFailed', 'מחיקת ההתאמה נכשלה: {error}'),

  ('en', 'adminDeleteUserSelfError', 'You cannot delete your own admin account.'),
  ('es', 'adminDeleteUserSelfError', 'No puedes eliminar tu propia cuenta de administrador.'),
  ('he', 'adminDeleteUserSelfError', 'לא ניתן למחוק את חשבון המנהל שלך.'),

  ('en', 'adminUserMatchNoUsersFound', 'No users found.'),
  ('es', 'adminUserMatchNoUsersFound', 'No se encontraron usuarios.'),
  ('he', 'adminUserMatchNoUsersFound', 'לא נמצאו משתמשים.'),

  ('en', 'adminUserMatchNoMatchesFound', 'No matches found.'),
  ('es', 'adminUserMatchNoMatchesFound', 'No se encontraron coincidencias.'),
  ('he', 'adminUserMatchNoMatchesFound', 'לא נמצאו התאמות.'),

  ('en', 'adminUserMatchSearchPromptUsers', 'Search for a user above to manage or delete.'),
  ('es', 'adminUserMatchSearchPromptUsers', 'Busca un usuario arriba para gestionar o eliminar.'),
  ('he', 'adminUserMatchSearchPromptUsers', 'חפשו משתמש למעלה כדי לנהל או למחוק.'),

  ('en', 'adminUserMatchSearchPromptMatches', 'Search for a match above to manage or delete.'),
  ('es', 'adminUserMatchSearchPromptMatches', 'Busca una coincidencia arriba para gestionar o eliminar.'),
  ('he', 'adminUserMatchSearchPromptMatches', 'חפשו התאמה למעלה כדי לנהל או למחוק.'),

  ('en', 'adminUserMatchDeleteUserButton', 'Delete user'),
  ('es', 'adminUserMatchDeleteUserButton', 'Eliminar usuario'),
  ('he', 'adminUserMatchDeleteUserButton', 'מחיקת משתמש'),

  ('en', 'adminUserMatchDeleteMatchButton', 'Delete match'),
  ('es', 'adminUserMatchDeleteMatchButton', 'Eliminar coincidencia'),
  ('he', 'adminUserMatchDeleteMatchButton', 'מחיקת התאמה'),

  ('en', 'adminUserMatchMessagesLabel', '{count} messages'),
  ('es', 'adminUserMatchMessagesLabel', '{count} mensajes'),
  ('he', 'adminUserMatchMessagesLabel', '{count} הודעות'),

  ('en', 'adminUserMatchOfflineError', 'Cannot delete while offline.'),
  ('es', 'adminUserMatchOfflineError', 'No se puede eliminar sin conexión.'),
  ('he', 'adminUserMatchOfflineError', 'לא ניתן למחוק במצב לא מקוון.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
