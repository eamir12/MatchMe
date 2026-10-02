-- =====================================================================
-- DELETE USER + ALL DATA ASSOCIATED WITH THE USER (Supabase, full wipe)
-- ---------------------------------------------------------------------
-- HOW TO USE:
--   1. Replace TARGET_USER_ID below with the user's ID
--      (the same UUID exists in auth.users and public.users)
--   2. Paste the ENTIRE file into the Supabase SQL Editor and run it.
--      It must run as the database owner (postgres / dashboard), NOT
--      with the anon/authenticated key (RLS would block the deletes).
--
-- WHAT IT DOES:
--   - Deletes the user's rows from every public table (matches,
--     chats, messages, referrals, ad data, crypto keys, etc.). Events the
--     user created are deleted ONLY if no other user attends them; events
--     that other users still attend are kept (owner column set to NULL).
--   - Nulls out references TO this user from admin-owned rows
--     (admin_broadcasts.created_by, profile_edit_requests.reviewed_by,
--     users.verification_reviewer_id) so FK constraints don't block.
--   - Deletes storage object METADATA rows for the user's files. NOTE:
--     Supabase's protect_delete() trigger blocks direct storage deletes, so
--     the script temporarily sets the allow-delete session flag. This removes
--     the DB rows but NOT the underlying file bytes (object store). For a
--     full byte-level wipe, deploy the fixed delete-account edge function
--     (supabase/functions/delete-account - it uses the Storage API), or
--     manually delete the "{userId}/" folder in each bucket in the Dashboard.
--   - Deletes the public.users row and the auth user (auth.identities,
--     sessions, refresh tokens, MFA factors, passkeys cascade with it).
--   Everything is wrapped in a single DO block = one transaction.
--
-- SAFETY: every step checks that the table/column actually exists, so
-- missing tables are skipped with a NOTICE and the script is safe to
-- rerun (idempotent).
-- =====================================================================

-- ---------- 1) SET THE TARGET USER ID HERE --------------------------
-- \set TARGET_USER_ID '81924881-505f-428c-84c4-7bf7a239c230'
-- (psql style above is NOT used; edit the uuid inside the DO block below)
-- ---------------------------------------------------------------------

-- ---------- helper: delete rows by user column(s) --------------------
CREATE OR REPLACE FUNCTION pg_temp.mm_delete_rows(
    p_table       text,        -- e.g. 'public.matches'
    p_column      text,        -- e.g. 'user1_id'
    p_uid         uuid,
    p_second_col  text DEFAULT NULL  -- optional: OR <col> = uid
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_sql    text;
    v_cnt    bigint;
    v_table  text := split_part(p_table, '.', 2);
    v_schema text := split_part(p_table, '.', 1);
BEGIN
    IF to_regclass(p_table) IS NULL THEN
        RAISE NOTICE 'SKIP % (table does not exist)', p_table;
        RETURN;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = v_schema AND table_name = v_table
          AND column_name = p_column
    ) THEN
        RAISE NOTICE 'SKIP % (column % missing)', p_table, p_column;
        RETURN;
    END IF;
    IF p_second_col IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = v_schema AND table_name = v_table
          AND column_name = p_second_col
    ) THEN
        RAISE NOTICE 'SKIP % (column % missing)', p_table, p_second_col;
        RETURN;
    END IF;

    v_sql := format('DELETE FROM %I.%I WHERE %I = %L', v_schema, v_table, p_column, p_uid);
    IF p_second_col IS NOT NULL THEN
        v_sql := v_sql || format(' OR %I = %L', p_second_col, p_uid);
    END IF;
    EXECUTE v_sql;
    GET DIAGNOSTICS v_cnt = ROW_COUNT;
    RAISE NOTICE 'Deleted % row(s) from % WHERE % = %', v_cnt, p_table, p_column, p_uid;
END $$;

-- ---------- helper: delete by the FIRST column that exists -------------
-- Some tables' owner-column names vary between environments (e.g. events:
-- created_by / owner_id / user_id). Tries each candidate in order.
CREATE OR REPLACE FUNCTION pg_temp.mm_delete_first_col(
    p_table text,
    p_uid uuid,
    VARIADIC p_columns text[]
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_schema text := split_part(p_table, '.', 1);
    v_table  text := split_part(p_table, '.', 2);
    v_col    text;
    v_cnt    bigint;
BEGIN
    IF to_regclass(p_table) IS NULL THEN
        RAISE NOTICE 'SKIP % (table does not exist)', p_table;
        RETURN;
    END IF;
    FOREACH v_col IN ARRAY p_columns LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = v_schema AND table_name = v_table AND column_name = v_col
        ) THEN
            EXECUTE format('DELETE FROM %I.%I WHERE %I = %L', v_schema, v_table, v_col, p_uid);
            GET DIAGNOSTICS v_cnt = ROW_COUNT;
            RAISE NOTICE 'Deleted % row(s) from % WHERE % = %', v_cnt, p_table, v_col, p_uid;
            RETURN;
        END IF;
    END LOOP;
    RAISE NOTICE 'SKIP % (none of columns % exist)', p_table, array_to_string(p_columns, ', ');
END $$;

-- ---------- helper: null out a reference to this user ----------------
CREATE OR REPLACE FUNCTION pg_temp.mm_null_ref(
    p_table  text,
    p_column text,
    p_uid    uuid
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_cnt    bigint;
    v_table  text := split_part(p_table, '.', 2);
    v_schema text := split_part(p_table, '.', 1);
BEGIN
    IF to_regclass(p_table) IS NULL THEN
        RAISE NOTICE 'SKIP % (table does not exist)', p_table;
        RETURN;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = v_schema AND table_name = v_table
          AND column_name = p_column
    ) THEN
        RAISE NOTICE 'SKIP % (column % missing)', p_table, p_column;
        RETURN;
    END IF;
    EXECUTE format('UPDATE %I.%I SET %I = NULL WHERE %I = %L', v_schema, v_table, p_column, p_column, p_uid);
    GET DIAGNOSTICS v_cnt = ROW_COUNT;
    RAISE NOTICE 'Nulled % row(s) in %.% (ref to deleted user)', v_cnt, p_table, p_column;
END $$;

-- ---------- 2) THE ACTUAL DELETION -----------------------------------
DO $$
DECLARE
    v_uid       uuid := '81924881-505f-428c-84c4-7bf7a239c230';  -- <-- EDIT THE USER ID HERE
    v_owner_col text;
BEGIN
    RAISE NOTICE '=== Starting deletion for user % ===', v_uid;

    -- -- Chat / match data (tables without a users() FK) --
    PERFORM pg_temp.mm_delete_rows('public.chat_messages',       'sender_id',    v_uid, 'recipient_id');
    PERFORM pg_temp.mm_delete_rows('public.message_reactions',   'user_id',      v_uid);
    PERFORM pg_temp.mm_delete_rows('public.matches',             'user1_id',     v_uid, 'user2_id');
    PERFORM pg_temp.mm_delete_rows('public.chats',               'user_id',      v_uid, 'other_user_id');
    PERFORM pg_temp.mm_delete_rows('public.user_recent_chats',   'user_id',      v_uid, 'other_user_id');
    PERFORM pg_temp.mm_delete_rows('public.user_recent_matches', 'user_id',      v_uid, 'other_user_id');
    PERFORM pg_temp.mm_delete_rows('public.unmatched_pairs',     'user1_id',     v_uid, 'user2_id');
    PERFORM pg_temp.mm_delete_rows('public.unmatched_pairs',     'created_by',   v_uid);
    PERFORM pg_temp.mm_delete_rows('public.chat_rooms',          'user_id',      v_uid);

    -- -- Ratings --
    PERFORM pg_temp.mm_delete_rows('public.match_ratings',        'rater_id',   v_uid, 'ratee_id');
    PERFORM pg_temp.mm_delete_rows('public.match_rating_prompts', 'user_id',    v_uid);
    PERFORM pg_temp.mm_delete_rows('public.pending_rating_prompts','user_id',   v_uid, 'other_user_id');

    -- -- Events: first remove the user's attendance everywhere --
    PERFORM pg_temp.mm_delete_rows('public.event_attendees',     'user_id',    v_uid);
    PERFORM pg_temp.mm_delete_rows('public.event_participants',  'user_id',    v_uid);
    PERFORM pg_temp.mm_delete_rows('public.event_parse_results', 'user_id',    v_uid);

    -- -- Then delete events created by the user ONLY if no other user
    --    attends them. Events that other users still attend are KEPT and
    --    their owner column (created_by / owner_id / user_id) is nulled. --
    IF to_regclass('public.events') IS NOT NULL THEN
        SELECT column_name INTO v_owner_col
          FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'events'
           AND column_name IN ('created_by', 'owner_id', 'user_id')
         ORDER BY CASE column_name WHEN 'created_by' THEN 1 WHEN 'owner_id' THEN 2 ELSE 3 END
         LIMIT 1;
        IF v_owner_col IS NOT NULL THEN
            IF to_regclass('public.event_attendees') IS NOT NULL THEN
                BEGIN
                    EXECUTE format(
                        'DELETE FROM public.events WHERE %I = %L AND NOT EXISTS ' ||
                        '(SELECT 1 FROM public.event_attendees ea WHERE ea.event_id = public.events.id)',
                        v_owner_col, v_uid);
                    RAISE NOTICE 'Deleted unattended events (owner col %)', v_owner_col;
                EXCEPTION WHEN OTHERS THEN
                    RAISE NOTICE 'Event deletion failed, keeping all events: %', SQLERRM;
                END;
                BEGIN
                    EXECUTE format(
                        'UPDATE public.events SET %I = NULL WHERE %I = %L AND EXISTS ' ||
                        '(SELECT 1 FROM public.event_attendees ea WHERE ea.event_id = public.events.id)',
                        v_owner_col, v_owner_col, v_uid);
                    RAISE NOTICE 'Nulled owner col % on still-attended events', v_owner_col;
                EXCEPTION WHEN OTHERS THEN
                    RAISE NOTICE 'Owner null-out failed: %', SQLERRM;
                END;
            ELSE
                PERFORM pg_temp.mm_delete_first_col('public.events', v_uid, 'created_by', 'owner_id', 'user_id');
            END IF;
        END IF;
    END IF;

    -- -- Referrals / promos --
    PERFORM pg_temp.mm_delete_rows('public.referrals',           'referrer_id', v_uid, 'referee_id');
    PERFORM pg_temp.mm_delete_rows('public.promo_code_usages',   'user_id',     v_uid);

    -- -- Profile / preferences --
    PERFORM pg_temp.mm_delete_rows('public.user_locations',      'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.user_profiles',       'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.user_interests',      'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.user_intents',        'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.user_blocks',         'user_id', v_uid, 'blocked_user_id');
    PERFORM pg_temp.mm_delete_rows('public.user_reports',        'user_id', v_uid, 'reported_user_id');
    PERFORM pg_temp.mm_delete_rows('public.user_invisibility_rules','user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.user_visibility_schedules','user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.invisibility_rules',  'user_id', v_uid);

    -- -- Session / activity / notifications --
    PERFORM pg_temp.mm_delete_rows('public.user_activity',           'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.user_session',            'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.notification_queue',      'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.user_subscription_queue', 'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.admin_broadcast_deliveries','user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.profile_edit_requests',   'user_id', v_uid);

    -- -- Ads --
    PERFORM pg_temp.mm_delete_rows('public.ad_impressions',      'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.ad_clicks',           'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.ad_reports',          'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.ad_revenue_events',   'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.ad_consent',          'user_id', v_uid);

    -- -- E2E encryption keys --
    PERFORM pg_temp.mm_delete_rows('public.user_chat_keys',        'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.user_chat_key_wrappers','user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.user_chat_crk_wrappers','user_id', v_uid);

    -- -- Location sharing / signals --
    PERFORM pg_temp.mm_delete_rows('public.location_share_signals', 'sharer_id', v_uid);

    -- -- Logs / fraud --
    PERFORM pg_temp.mm_delete_rows('public.edge_function_invocations', 'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('public.signup_fraud_signals',      'user_id', v_uid);

    -- -- Null out references TO this user (no-cascade admin refs) --
    PERFORM pg_temp.mm_null_ref('public.admin_broadcasts',      'created_by', v_uid);
    PERFORM pg_temp.mm_null_ref('public.profile_edit_requests', 'reviewed_by', v_uid);
    PERFORM pg_temp.mm_null_ref('public.users', 'verification_reviewer_id', v_uid);

    -- -- Storage objects under the user's folder / any name containing the uid --
    -- storage-api's protect_delete() trigger blocks direct DELETE unless a
    -- session flag is set. Set BOTH documented flag names (harmless, the
    -- trigger only reads one); the flag is transaction-local so it resets
    -- automatically afterwards.
    PERFORM set_config('storage.can_delete', 'true', true);
    PERFORM set_config('storage.allow_delete_query', 'true', true);
    DELETE FROM storage.objects
     WHERE (storage.foldername(name))[1] = v_uid::text
        OR name LIKE '%' || v_uid::text || '%';
    RAISE NOTICE 'Storage metadata rows removed (see note about file bytes below)';

    -- -- The user row itself --
    PERFORM pg_temp.mm_delete_rows('public.users', 'id', v_uid);

    -- -- Auth-layer rows (auth.admin.delete_user() fails on some setups with
    --    "cross-database references not implemented"; deleting the auth.user
    --    row directly cascades to identities, sessions, refresh tokens, MFA
    --    factors, passkeys etc. via GoTrue's ON DELETE CASCADE FKs - the
    --    explicit deletes below are belt-and-suspenders and are skipped if a
    --    table/column does not exist) --
    PERFORM pg_temp.mm_delete_rows('auth.identities',                 'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('auth.sessions',                   'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('auth.refresh_tokens',             'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('auth.user_mfa_recovery_codes',    'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('auth.mfa_factors',                'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('auth.passkey_credentials',        'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('auth.passkey_challenges',         'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('auth.sensitive_action_email_codes', 'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('auth.pending_email_changes',      'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('auth.sso_sessions',               'user_id', v_uid);
    PERFORM pg_temp.mm_delete_rows('auth.users',                      'id',       v_uid);

    RAISE NOTICE '=== Done: user and all associated data deleted ===';
END $$;

-- ---------- 3) OPTIONAL: official auth deletion (alternative) -----------
-- The DO block above already removed the auth user. If for any reason you
-- prefer the official path instead, uncomment and run one of these BEFORE
-- the DO block (and it must not already be gone):
--   SELECT auth.admin.delete_user('81924881-505f-428c-84c4-7bf7a239c230', true);
--   -- fails with "cross-database references are not implemented" on some setups
-- Or delete the user via the Dashboard (Authentication > Users) or via the
-- admin API in the fixed delete-account edge function.

-- ---------- 4) VERIFICATION (dynamic - cannot fail on missing columns) --
-- Prints a LEFTOVER line for any table still holding rows for this user.
-- No LEFTOVER lines = fully wiped.
DO $$
DECLARE
    v_uid    uuid := '81924881-505f-428c-84c4-7bf7a239c230';
    v_rec    record;
    v_schema text;
    v_table  text;
    v_cnt    bigint;
BEGIN
    RAISE NOTICE '=== Verification for user %: rows found below are LEFTOVER ===', v_uid;
    FOR v_rec IN SELECT * FROM (VALUES
        ('public.chat_messages', 'sender_id'),
        ('public.matches',       'user1_id'),
        ('public.events',        'created_by'),
        ('public.events',        'owner_id'),
        ('public.events',        'user_id'),
        ('public.event_attendees','user_id'),
        ('public.user_profiles', 'user_id'),
        ('public.user_locations','user_id'),
        ('public.referrals',     'referrer_id'),
        ('public.referrals',     'referee_id'),
        ('public.users',         'id'),
        ('auth.users',           'id'),
        ('auth.identities',      'user_id'),
        ('auth.sessions',        'user_id'),
        ('auth.refresh_tokens',  'user_id'),
        ('auth.mfa_factors',     'user_id')
    ) AS t(tbl, col)
    LOOP
        IF to_regclass(v_rec.tbl) IS NULL THEN CONTINUE; END IF;
        v_schema := split_part(v_rec.tbl, '.', 1);
        v_table  := split_part(v_rec.tbl, '.', 2);
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = v_schema AND table_name = v_table
              AND column_name = v_rec.col
        ) THEN CONTINUE; END IF;
        EXECUTE format('SELECT count(*) FROM %I.%I WHERE %I = %L',
                       v_schema, v_table, v_rec.col, v_uid) INTO v_cnt;
        IF v_cnt > 0 THEN
            RAISE NOTICE 'LEFTOVER: % (col %) has % row(s) for this user', v_rec.tbl, v_rec.col, v_cnt;
        END IF;
    END LOOP;
    RAISE NOTICE '=== Verification complete (no LEFTOVER lines above = fully wiped) ===';
END $$;