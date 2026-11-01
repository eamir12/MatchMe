-- Migration: pin search_path on the 11 unpinned SECURITY DEFINER functions and
-- close the schema-shadowing vector that made "search_path = public" useless.
-- Date: 2026-10-29
--
-- 11 SECURITY DEFINER functions have no pinned search_path (proconfig is null):
--   approve_primary_photo, cleanup_pending_email_changes, complete_email_change,
--   edit_chat_message, generate_email_change_code,
--   generate_sensitive_action_email_code, get_message_reactors, mask_full_name,
--   update_user_activity, verify_email_change_code,
--   verify_sensitive_action_email_code
--
-- Why they do not get "search_path = public" like most of the other 327:
--   338 SECURITY DEFINER functions exist; 327 are already pinned, and 316 of
--   those pinned paths include public.
--   public ACL = {postgres=UC, anon=UC, authenticated=UC, service_role=UC,
--                 supabase_auth_admin=U}
--   anon and authenticated hold CREATE on public. A signed-in user (or anyone
--   with the anon key) can therefore create public.<name> and have an unqualified
--   call inside a SECURITY DEFINER body resolve to their function, running as the
--   owner (postgres). For the two email-code functions that call
--   pgp_sym_encrypt / pgp_sym_decrypt unqualified, public.pgp_sym_encrypt() did
--   not exist, so it was free for an attacker to create: a direct path from a
--   client request to code execution as postgres.
--   extensions ACL = {postgres=UC, anon=U, authenticated=U, service_role=U} —
--   no CREATE for client roles, so it is safe to put in the path.
--
-- Fix:
--   * revoke CREATE on schema public from anon and authenticated. This also
--     protects the 316 already-pinned functions whose search_path includes
--     public. No object in any non-system schema is owned by
--     anon/authenticated (checked in production 2026-10-29), so no existing
--     object is affected.
--   * nine functions are fully schema-qualified already -> search_path = ''
--     (only pg_catalog, which is always implicitly present, plus pg_temp for
--     relations; pg_temp is never searched for functions).
--   * the two that call pgcrypto unqualified -> search_path = extensions.
--   * update_user_activity carried its own `SET search_path = 'public'` inside
--     the body, which overrides any function-level setting and points the
--     function at the writable schema. It is recreated with schema-qualified
--     table names and no internal SET. The S2 identity guard is copied
--     verbatim. CREATE OR REPLACE keeps the oid, owner and ACL; volatility,
--     strictness and proconfig are re-set by the statement.
--
-- Blast radius: schema CREATE privilege, function proconfig, and one function
-- body (update_user_activity: table names qualified, internal SET removed).
-- No table, column, grant or policy changes.
-- Rollback: alter function <signature> reset search_path;  and
--           grant create on schema public to anon, authenticated;  (not advised)
--
-- Verification (run after applying):
--   select p.proname, p.proconfig
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public'
--     and p.proname in ('approve_primary_photo','cleanup_pending_email_changes',
--       'complete_email_change','edit_chat_message','generate_email_change_code',
--       'generate_sensitive_action_email_code','get_message_reactors',
--       'mask_full_name','update_user_activity','verify_email_change_code',
--       'verify_sensitive_action_email_code')
--   order by 1;
--   -- expect {search_path=""} x9 and {search_path=extensions} x2
--   select p.proname,
--          has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec
--   from pg_proc p where p.oid in (
--     'public.cleanup_pending_email_changes()'::regprocedure,
--     'public.update_user_activity(uuid)'::regprocedure);
--   -- expect cleanup_pending_email_changes false (S1b revoked it), others true
--   select has_schema_privilege('anon','public','CREATE') as anon_create,
--          has_schema_privilege('authenticated','public','CREATE') as auth_create;
--   -- expect false, false
--   select p.prosrc ilike '%not authorized%' as guard_present,
--          p.prosrc ~* 'set +search_path' as internal_set_present     -- body only
--   from pg_proc p where p.oid = 'public.update_user_activity(uuid)'::regprocedure;
--   -- expect true, false

revoke create on schema public from anon, authenticated;

alter function public.approve_primary_photo(p_user_id uuid, p_photo_path text)
  set search_path = '';
alter function public.cleanup_pending_email_changes()
  set search_path = '';
alter function public.complete_email_change(p_user_id uuid, p_code text)
  set search_path = '';
alter function public.edit_chat_message(p_message_id uuid, p_content_original_encrypted text, p_content_original_nonce text, p_wrapped_keys jsonb, p_sender_key_id uuid, p_recipient_key_id uuid, p_recipient_id uuid)
  set search_path = '';
alter function public.generate_email_change_code(p_user_id uuid, p_new_email text)
  set search_path = '';
alter function public.generate_sensitive_action_email_code(p_user_id uuid, p_email text)
  set search_path = extensions;
alter function public.get_message_reactors(message_id uuid, reaction text)
  set search_path = '';
alter function public.mask_full_name(full_name text)
  set search_path = '';
alter function public.verify_email_change_code(p_user_id uuid, p_code text)
  set search_path = '';
alter function public.verify_sensitive_action_email_code(p_user_id uuid, p_email text, p_code text)
  set search_path = extensions;

create or replace function public.update_user_activity(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
DECLARE
    is_visible BOOLEAN;
    is_banned BOOLEAN;
    user_exists BOOLEAN;
    has_active_session BOOLEAN;
    has_revoked_session BOOLEAN;
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

    -- Check if user exists in the users table
    SELECT EXISTS(SELECT 1 FROM public.users WHERE id = p_user_id)
    INTO user_exists;

    -- If user doesn't exist (has been deleted), return early silently
    -- This prevents NULL constraint violations on is_visible
    IF NOT user_exists THEN
        RETURN;
    END IF;

    -- Get current visibility and ban status
    SELECT
        COALESCE(user_visibility_setting, false),
        COALESCE(system_visibility_status, 'visible') = 'banned'
    INTO is_visible, is_banned
    FROM public.users
    WHERE id = p_user_id;

    -- If user is banned, force offline
    IF is_banned THEN
        UPDATE public.user_activity
        SET is_online = false,
            last_activity = NOW(),
            updated_at = NOW()
        WHERE user_id = p_user_id;
    ELSE
        -- Session-state gate: a revoked session (logout) must never be
        -- resurrected by a stale heartbeat, but a logged-in user whose
        -- registration was skipped (no GPS country) has no rows at all
        -- and must stay online.
        SELECT EXISTS (
            SELECT 1 FROM public.user_session
            WHERE user_id = p_user_id AND revoked = false
        )
        INTO has_active_session;

        SELECT EXISTS (
            SELECT 1 FROM public.user_session
            WHERE user_id = p_user_id AND revoked = true
        )
        INTO has_revoked_session;

        IF (NOT COALESCE(has_active_session, false))
           AND COALESCE(has_revoked_session, false) THEN
            -- Logged out: keep the user offline. Also refresh last_activity
            -- so the 61s online-count window keeps excluding them.
            UPDATE public.user_activity
            SET is_online = false,
                last_activity = NOW(),
                updated_at = NOW()
            WHERE user_id = p_user_id;
        ELSE
            -- Update activity with current visibility status
            INSERT INTO public.user_activity (
                user_id,
                last_activity,
                is_online,
                is_visible,
                updated_at
            )
            VALUES (
                p_user_id,
                NOW(),
                true,
                is_visible,
                NOW()
            )
            ON CONFLICT (user_id)
            DO UPDATE SET
                last_activity = NOW(),
                is_online = true,
                is_visible = EXCLUDED.is_visible,
                updated_at = NOW();
        END IF;
    END IF;
END;
$function$;

do $$
declare
  expected text[][];
  i int;
  cfg text;
  oid_ oid;
begin
  -- signature | pinned search_path | authenticated EXECUTE after this migration
  -- cleanup_pending_email_changes lost authenticated EXECUTE in
  -- 20262205000000; ALTER FUNCTION preserves that ACL and the assertion pins it.
  expected := array[
    ['public.approve_primary_photo(uuid,text)',                          'search_path=""',         'true'],
    ['public.cleanup_pending_email_changes()',                           'search_path=""',         'false'],
    ['public.complete_email_change(uuid,text)',                          'search_path=""',         'true'],
    ['public.edit_chat_message(uuid,text,text,jsonb,uuid,uuid,uuid)',    'search_path=""',         'true'],
    ['public.generate_email_change_code(uuid,text)',                     'search_path=""',         'true'],
    ['public.generate_sensitive_action_email_code(uuid,text)',           'search_path=extensions', 'true'],
    ['public.get_message_reactors(uuid,text)',                           'search_path=""',         'true'],
    ['public.mask_full_name(text)',                                      'search_path=""',         'true'],
    ['public.update_user_activity(uuid)',                                'search_path=""',         'true'],
    ['public.verify_email_change_code(uuid,text)',                       'search_path=""',         'true'],
    ['public.verify_sensitive_action_email_code(uuid,text,text)',        'search_path=extensions', 'true']
  ];

  for i in 1 .. array_length(expected, 1) loop
    oid_ := expected[i][1]::regprocedure;
    if not exists (
      select 1 from pg_proc p
      where p.oid = oid_ and p.proconfig @> array[expected[i][2]]
    ) then
      raise exception 'search_path not pinned as % on %', expected[i][2], expected[i][1];
    end if;
    if not has_function_privilege('service_role', oid_, 'EXECUTE') then
      raise exception 'service_role lost EXECUTE on %', expected[i][1];
    end if;
    if has_function_privilege('authenticated', oid_, 'EXECUTE') is distinct from expected[i][3]::boolean then
      raise exception 'authenticated EXECUTE on % is %, expected %',
        expected[i][1],
        has_function_privilege('authenticated', oid_, 'EXECUTE'),
        expected[i][3];
    end if;
    if pg_get_userbyid((select proowner from pg_proc where oid = oid_)) <> 'postgres' then
      raise exception 'owner changed on %', expected[i][1];
    end if;
  end loop;

  if has_schema_privilege('anon', 'public', 'CREATE') then
    raise exception 'anon still has CREATE on schema public';
  end if;
  if has_schema_privilege('authenticated', 'public', 'CREATE') then
    raise exception 'authenticated still has CREATE on schema public';
  end if;

  -- prosrc is the body only; pg_get_functiondef also prints the function-level
  -- SET search_path, which is expected.
  select p.prosrc into cfg
  from pg_proc p
  where p.oid = 'public.update_user_activity(uuid)'::regprocedure;

  if cfg not ilike '%not authorized%' then
    raise exception 'update_user_activity lost the identity guard';
  end if;
  if cfg ~* 'set +search_path' then
    raise exception 'update_user_activity still sets search_path in its body';
  end if;
end $$;

notify pgrst, 'reload schema';
