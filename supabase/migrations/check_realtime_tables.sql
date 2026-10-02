-- Check which tables needed by admin app realtime subscriptions are enabled.
-- Tables subscribed via .onPostgresChanges() or .stream() need to be in the
-- supabase_realtime publication for PostgreSQL logical replication to work.

with
  needed (ord, schema_name, table_name) as (
    values
      -- Main dashboard (onPostgresChanges)
      (1,  'public', 'admin_dashboard_tick'),
      -- Broadcasts screen (onPostgresChanges)
      (2,  'public', 'admin_broadcasts'),
      (3,  'public', 'admin_broadcast_deliveries'),
      -- Sponsored ads dashboard (stream)
      (4,  'public', 'app_config'),
      (5,  'public', 'ad_campaigns'),
      (6,  'public', 'ad_creatives'),
      (7,  'public', 'ad_impressions'),
      (8,  'public', 'ad_clicks'),
      (9,  'public', 'ad_reports'),
      -- External ads dashboard (stream)
      (10, 'public', 'ad_revenue_events'),
      (11, 'public', 'ad_networks')
  ),
  enabled as (
    select schemaname, tablename
    from pg_publication_tables
    where pubname = 'supabase_realtime'
  )
select
  n.table_name,
  case
    when e.tablename is not null then '✅ ENABLED'
    else '❌ NOT ENABLED'
  end as realtime_status,
  case
    when e.tablename is not null then 'In supabase_realtime publication'
    else 'MISSING from supabase_realtime publication'
  end as details
from needed n
left join enabled e
  on e.schemaname = n.schema_name and e.tablename = n.table_name
order by n.ord;

-- Summary
with
  needed (schema_name, table_name) as (
    values
      ('public', 'admin_dashboard_tick'),
      ('public', 'admin_broadcasts'),
      ('public', 'admin_broadcast_deliveries'),
      ('public', 'app_config'),
      ('public', 'ad_campaigns'),
      ('public', 'ad_creatives'),
      ('public', 'ad_impressions'),
      ('public', 'ad_clicks'),
      ('public', 'ad_reports'),
      ('public', 'ad_revenue_events'),
      ('public', 'ad_networks')
  ),
  enabled as (
    select schemaname, tablename
    from pg_publication_tables
    where pubname = 'supabase_realtime'
  )
select
  count(*) filter (where e.tablename is not null) as tables_enabled,
  count(*) filter (where e.tablename is null)     as tables_missing
from needed n
left join enabled e
  on e.schemaname = n.schema_name and e.tablename = n.table_name;

-- Fix missing tables (run this if any are missing above)
-- do $$
--   declare
--     missing text[] := array(
--       with
--         needed (schema_name, table_name) as (
--           values
--             ('public', 'admin_dashboard_tick'),
--             ('public', 'admin_broadcasts'),
--             ('public', 'admin_broadcast_deliveries'),
--             ('public', 'app_config'),
--             ('public', 'ad_campaigns'),
--             ('public', 'ad_creatives'),
--             ('public', 'ad_impressions'),
--             ('public', 'ad_clicks'),
--             ('public', 'ad_reports'),
--             ('public', 'ad_revenue_events'),
--             ('public', 'ad_networks')
--         ),
--         enabled as (
--           select tablename from pg_publication_tables
--           where pubname = 'supabase_realtime'
--         )
--       select n.table_name
--       from needed n
--       left join enabled e on e.tablename = n.table_name
--       where e.tablename is null
--     );
--     t text;
--   begin
--     foreach t in array missing loop
--       execute format('alter publication supabase_realtime add table public.%I;', t);
--       raise notice 'Added % to supabase_realtime', t;
--     end loop;
--   end;
-- $$;

-- Reference: list everything currently in the publication
select
  schemaname,
  tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
order by schemaname, tablename;
