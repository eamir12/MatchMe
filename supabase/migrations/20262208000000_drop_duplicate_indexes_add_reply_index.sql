-- Migration: drop 13 duplicate indexes, add the reply_to_message_id FK index
-- Date: 2026-10-29
--
-- Why: 13 index pairs in public are byte-for-byte equivalent (same table,
-- columns, predicate, uniqueness). Each duplicate doubles the write cost and
-- WAL for its table while never being chosen over its twin. The kept member
-- of every pair is either the constraint-backed index (cannot be dropped) or
-- the one the planner actually uses.
--
--   table                      definition                         drop                                   keep
--   app_config                 btree (config_key)                 idx_app_config_key                     app_config_config_key_key (unique)
--   intents                    btree (key)                        intents_key_idx                        intents_key_key (unique)
--   interests                  btree (key)                        interests_key_idx                      interests_key_key (unique)
--   promo_codes                btree (code)                       idx_promo_codes_code                   promo_codes_code_key (unique)
--   referrals                  btree (referee_id)                 idx_referrals_referee                  referrals_referee_id_key (unique)
--   user_activity              btree (last_activity) WHERE online idx_user_activity_online_recent        idx_user_activity_stale_online
--   user_activity              btree (user_id) unique             idx_user_activity_user_id_unique       user_activity_pkey (PK)
--   user_locations             btree (user_id) unique             idx_user_locations_user_id_unique      user_locations_pkey (PK)
--   user_subscription_queue    btree (starts_at)                  idx_subscription_queue_starts_at       idx_user_subscription_queue_starts_at
--   user_subscription_queue    btree (status)                     idx_subscription_queue_status          idx_user_subscription_queue_status
--   user_subscription_queue    btree (user_id, status)            idx_subscription_queue_user_status     idx_user_subscription_queue_user_status
--   user_subscription_queue    btree (user_id)                    idx_subscription_queue_user_id         idx_user_subscription_queue_user_id
--   users                      btree (referral_code)              idx_users_referral_code                users_referral_code_key (unique)
--
-- Adds idx_chat_messages_reply_to_message_id. fk_chat_messages_reply_to_message
-- (ON DELETE SET NULL) has no supporting index, so every parent-message delete
-- seq-scans chat_messages. The table is 528 kB / 214 rows, so a plain
-- CREATE INDEX (SHARE lock, blocks writes for milliseconds) is enough; no
-- CONCURRENTLY, which cannot run inside a migration transaction.
--
-- Blast radius: 13 index drops (ACCESS EXCLUSIVE per table, held to commit)
-- and 1 index build on a 528 kB table. No data, column, constraint or policy
-- change. Query plans that used a dropped twin shift to the identical kept
-- index.
--
-- Rollback: recreate any dropped index from this file's table above; drop
-- idx_chat_messages_reply_to_message_id.
--
-- Verification: the DO block fails the migration if a dropped name survives,
-- a kept/new index is missing or invalid, or any duplicate index definition
-- remains in public.

set statement_timeout = '120s';
set lock_timeout = '5s';

drop index if exists public.idx_app_config_key;
drop index if exists public.intents_key_idx;
drop index if exists public.interests_key_idx;
drop index if exists public.idx_promo_codes_code;
drop index if exists public.idx_referrals_referee;
drop index if exists public.idx_user_activity_user_id_unique;
drop index if exists public.idx_user_locations_user_id_unique;
drop index if exists public.idx_user_activity_online_recent;
drop index if exists public.idx_subscription_queue_starts_at;
drop index if exists public.idx_subscription_queue_status;
drop index if exists public.idx_subscription_queue_user_status;
drop index if exists public.idx_subscription_queue_user_id;
drop index if exists public.idx_users_referral_code;

create index if not exists idx_chat_messages_reply_to_message_id
  on public.chat_messages (reply_to_message_id);

do $$
declare
  v_dropped text[] := array[
    'idx_app_config_key',
    'intents_key_idx',
    'interests_key_idx',
    'idx_promo_codes_code',
    'idx_referrals_referee',
    'idx_user_activity_user_id_unique',
    'idx_user_locations_user_id_unique',
    'idx_user_activity_online_recent',
    'idx_subscription_queue_starts_at',
    'idx_subscription_queue_status',
    'idx_subscription_queue_user_status',
    'idx_subscription_queue_user_id',
    'idx_users_referral_code'
  ];
  v_kept text[] := array[
    'app_config_config_key_key',
    'intents_key_key',
    'interests_key_key',
    'promo_codes_code_key',
    'referrals_referee_id_key',
    'idx_user_activity_stale_online',
    'user_activity_pkey',
    'user_locations_pkey',
    'idx_user_subscription_queue_starts_at',
    'idx_user_subscription_queue_status',
    'idx_user_subscription_queue_user_status',
    'idx_user_subscription_queue_user_id',
    'users_referral_code_key',
    'idx_chat_messages_reply_to_message_id'
  ];
  v_name text;
  v_dups bigint;
begin
  foreach v_name in array v_dropped loop
    if to_regclass('public.' || v_name) is not null then
      raise exception 'index % still exists', v_name;
    end if;
  end loop;

  foreach v_name in array v_kept loop
    if to_regclass('public.' || v_name) is null then
      raise exception 'index % is missing', v_name;
    end if;
    if not (select i.indisvalid from pg_index i
            where i.indexrelid = to_regclass('public.' || v_name)) then
      raise exception 'index % is not valid', v_name;
    end if;
  end loop;

  -- Same-column duplicates count even when only one member is UNIQUE: the
  -- unique index serves every lookup the plain twin serves. This matches the
  -- inventory that found the 13 groups.
  select count(*) into v_dups
  from (
    select i.indrelid,
           i.indkey::text,
           i.indclass::text,
           i.indcollation::text,
           i.indoption::text,
           coalesce(i.indpred::text, ''),
           coalesce(i.indexprs::text, '')
    from pg_index i
    join pg_class c on c.oid = i.indexrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and i.indisvalid
    group by 1, 2, 3, 4, 5, 6, 7
    having count(*) > 1
  ) d;

  if v_dups > 0 then
    raise exception '% duplicate index definitions remain in public', v_dups;
  end if;
end $$;
