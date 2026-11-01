-- Migration: pin search_path on the 24 remaining SECURITY INVOKER functions
-- flagged by the Supabase advisor (function_search_path_mutable).
-- Date: 2026-10-29
--
-- Pre-state (production, verified 2026-10-29): 24 public functions have
-- proconfig = null and are executable by authenticated (23 also by PUBLIC/anon).
-- All 24 are SECURITY INVOKER, so there is no privilege escalation; the hazard
-- is name resolution. An unqualified name inside the body resolves against
-- whatever search_path the caller happens to have, which is the correctness
-- bug the advisor flags and shadowing material if a schema in the path ever
-- becomes writable again.
--
-- Pin choices, decided by reading every body from pg_get_functiondef:
--   * 23 x search_path = '' — each body uses only pg_catalog builtins and/or
--     already schema-qualified objects (public.*, auth.*).
--   * check_preference_filter x search_path = public — it calls
--     _filter_values(...) six times without a qualifier; pinning '' would
--     break it (proven on a scratch cluster: the call fails with "No function
--     matches the given name... _filter_values"). This is also load-bearing
--     after this migration pins are_filters_compatible to '': a function-level
--     search_path applies to nested calls, so
--     are_filters_compatible -> check_preference_filter would otherwise
--     inherit '' and fail to resolve _filter_values. Client roles lost CREATE
--     on schema public in 20262206000000, so the path cannot be shadowed by
--     anon/authenticated.
--
-- Two overload notes:
--   * get_user_chats(uuid) is already pinned (search_path=public, auth,
--     extensions); only get_user_chats(uuid, integer) is flagged.
--   * upsert_chat_row(8 args) is SECURITY DEFINER and already pinned
--     (search_path=public); only the 7-arg SECURITY INVOKER overload is
--     flagged. The signatures below are exact.
--
-- Structure: one DO block. The alternative (temp table + static ALTER
-- statements) silently loses state whenever the script is executed in
-- autocommit mode, because `on commit drop` fires per statement. Keeping the
-- whole batch in one statement also makes it atomic under every execution
-- mode (SQL editor, psql, db push) and lets the block prove, in the same
-- transaction, that every body, ACL, owner and volatility is unchanged.
--
-- Blast radius: pg_proc.proconfig on 24 functions only. No body, owner, ACL,
-- volatility, strictness, schema or table change; ALTER FUNCTION ... SET is
-- metadata-only DDL. The two SQL-language functions (get_user_chats,
-- get_user_recent_chats) have no SQL callers — no function, view or policy
-- references them; the app calls them as top-level PostgREST RPCs — so no
-- plan-inlining path exists.
--
-- Rollback: alter function public.<signature> reset search_path;  (x24 below)
--
-- Verification after apply:
--   select p.oid::regprocedure as sig, p.proconfig
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and not p.prosecdef and p.proconfig is null
--     and has_function_privilege('authenticated', p.oid, 'EXECUTE');
--   -- expect 0 rows
--   select count(*) filter (where p.proconfig @> array['search_path=""'])     as empty_path,
--          count(*) filter (where p.proconfig @> array['search_path=public']) as public_path
--   from pg_proc p
--   where p.oid in (
--     'public._filter_values(jsonb,text)'::regprocedure,
--     'public._is_romantic_intent(text)'::regprocedure,
--     'public._match_extended_push_enabled(jsonb,text,text)'::regprocedure,
--     'public.are_filters_compatible(jsonb,jsonb,jsonb,integer,jsonb,jsonb,jsonb,integer,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb,text)'::regprocedure,
--     'public.bio_texts_too_similar(text,text)'::regprocedure,
--     'public.block_protected_user_fields_update()'::regprocedure,
--     'public.check_preference_filter(jsonb,jsonb,integer,text)'::regprocedure,
--     'public.clean_interest_map(jsonb)'::regprocedure,
--     'public.enforce_basic_details_one_time_edit()'::regprocedure,
--     'public.enforce_unique_profile_bio()'::regprocedure,
--     'public.get_enforcement_flag(jsonb,text,text)'::regprocedure,
--     'public.get_user_chats(uuid,integer)'::regprocedure,
--     'public.get_user_recent_chats(uuid,integer)'::regprocedure,
--     'public.handle_chat_message_update_for_chats()'::regprocedure,
--     'public.is_compliant_candidate(jsonb,jsonb,text,date,text)'::regprocedure,
--     'public.meetup_scope_match_id(text)'::regprocedure,
--     'public.merge_interest_maps(jsonb,jsonb)'::regprocedure,
--     'public.prevent_sensitive_user_field_updates()'::regprocedure,
--     'public.profile_completeness_score(public.user_profiles)'::regprocedure,
--     'public.set_chat_translation(uuid,uuid,boolean,text)'::regprocedure,
--     'public.set_profile_completeness()'::regprocedure,
--     'public.update_app_config_updated_at()'::regprocedure,
--     'public.upsert_chat_row(uuid,uuid,uuid,uuid,timestamptz,integer,timestamptz)'::regprocedure,
--     'public.validate_chats_on_delete()'::regprocedure);
--   -- expect 23, 1

set lock_timeout = '5s';
set statement_timeout = '120s';

do $$
declare
  sigs constant text[] := array[
    'public._filter_values(jsonb,text)',
    'public._is_romantic_intent(text)',
    'public._match_extended_push_enabled(jsonb,text,text)',
    'public.are_filters_compatible(jsonb,jsonb,jsonb,integer,jsonb,jsonb,jsonb,integer,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb,text)',
    'public.bio_texts_too_similar(text,text)',
    'public.block_protected_user_fields_update()',
    'public.check_preference_filter(jsonb,jsonb,integer,text)',
    'public.clean_interest_map(jsonb)',
    'public.enforce_basic_details_one_time_edit()',
    'public.enforce_unique_profile_bio()',
    'public.get_enforcement_flag(jsonb,text,text)',
    'public.get_user_chats(uuid,integer)',
    'public.get_user_recent_chats(uuid,integer)',
    'public.handle_chat_message_update_for_chats()',
    'public.is_compliant_candidate(jsonb,jsonb,text,date,text)',
    'public.meetup_scope_match_id(text)',
    'public.merge_interest_maps(jsonb,jsonb)',
    'public.prevent_sensitive_user_field_updates()',
    'public.profile_completeness_score(public.user_profiles)',
    'public.set_chat_translation(uuid,uuid,boolean,text)',
    'public.set_profile_completeness()',
    'public.update_app_config_updated_at()',
    'public.upsert_chat_row(uuid,uuid,uuid,uuid,timestamptz,integer,timestamptz)',
    'public.validate_chats_on_delete()'
  ];
  cfgs constant text[] := array[
    '',
    '',
    '',
    '',
    '',
    '',
    'public',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    ''
  ];
  n integer := array_length(sigs, 1);
  i integer;
  oid_ oid;
  v_secdef boolean;
  v_md5 text;
  v_acl text;
  v_owner text;
  v_vol "char";
  cfg text[];
  cfg_expected text;
  md5_now text;
  acl_now text;
  owner_now text;
  vol_now "char";
  remaining integer;
begin
  if array_length(cfgs, 1) <> n or n <> 24 then
    raise exception 'signature/config lists are not 24 rows (%, %, %)',
      n, array_length(cfgs, 1), 24;
  end if;

  -- Capture + alter in one pass.
  for i in 1 .. n loop
    oid_ := sigs[i]::regprocedure;

    select p.prosecdef, md5(p.prosrc), coalesce(p.proacl::text, ''),
           pg_get_userbyid(p.proowner), p.provolatile
      into v_secdef, v_md5, v_acl, v_owner, v_vol
    from pg_proc p
    where p.oid = oid_;

    if v_secdef then
      raise exception '% is SECURITY DEFINER; only invoker functions belong in this batch', sigs[i];
    end if;

    execute format('alter function %s set search_path = %L', sigs[i], cfgs[i]);

    -- proconfig stores an empty setting as name="".
    cfg_expected := 'search_path=' || case when cfgs[i] = '' then '""' else cfgs[i] end;

    -- Verify immediately: config applied, everything else untouched.
    select p.proconfig, md5(p.prosrc), coalesce(p.proacl::text, ''),
           pg_get_userbyid(p.proowner), p.provolatile
      into cfg, md5_now, acl_now, owner_now, vol_now
    from pg_proc p
    where p.oid = oid_;

    if cfg is null or not (cfg @> array[cfg_expected]) then
      raise exception 'search_path on % is %, expected %', sigs[i], cfg, cfg_expected;
    end if;
    if md5_now is distinct from v_md5 then
      raise exception 'body changed on %', sigs[i];
    end if;
    if acl_now is distinct from v_acl then
      raise exception 'ACL changed on %', sigs[i];
    end if;
    if owner_now is distinct from v_owner then
      raise exception 'owner changed on %', sigs[i];
    end if;
    if vol_now is distinct from v_vol then
      raise exception 'volatility changed on %', sigs[i];
    end if;
  end loop;

  select count(*) into remaining
  from pg_proc p
  join pg_namespace n2 on n2.oid = p.pronamespace
  where n2.nspname = 'public'
    and p.prokind = 'f'
    and not p.prosecdef
    and p.proconfig is null
    and has_function_privilege('authenticated', p.oid, 'EXECUTE');

  if remaining <> 0 then
    raise exception '% public SECURITY INVOKER function(s) still have a mutable search_path', remaining;
  end if;
end $$;

notify pgrst, 'reload schema';
