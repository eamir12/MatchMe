-- ============================================================================
-- enable_realtime_promo_codes_ad_networks.sql  (READ-ONLY DIAGNOSTIC + FIX)
--
-- Purpose: the admin app's promo-codes refresher (promo_codes) and external-ads
-- network-status stream (ad_networks) subscribe to these tables, but NO
-- migration ever added them to the supabase_realtime publication — their
-- realtime legs would silently receive zero events (only the poll fallback
-- would work).
--
-- Section 1 shows current membership; Section 2 adds the missing tables
-- idempotently (safe to re-run).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Pre-check: what is currently in the publication?
-- ---------------------------------------------------------------------------
select tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
  and tablename in ('promo_codes', 'ad_networks')
order by tablename;

-- ---------------------------------------------------------------------------
-- 2. Add the missing tables to the publication (idempotent)
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'promo_codes'
  ) then
    alter publication supabase_realtime add table promo_codes;
    raise notice 'Added promo_codes to supabase_realtime';
  else
    raise notice 'promo_codes already in supabase_realtime';
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'ad_networks'
  ) then
    alter publication supabase_realtime add table ad_networks;
    raise notice 'Added ad_networks to supabase_realtime';
  else
    raise notice 'ad_networks already in supabase_realtime';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Verify
-- ---------------------------------------------------------------------------
select tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
  and tablename in ('promo_codes', 'ad_networks')
order by tablename;
