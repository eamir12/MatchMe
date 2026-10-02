-- Align all online/visible user time windows to 61 seconds.
--
-- Problem: get_online_users_count() uses 61 seconds, but the visible_users
-- count in admin_get_dashboard_stats and the online_users/visible_users
-- drilldown in admin_get_dashboard_drilldown used 45 seconds.
--
-- This meant the dashboard tile showed a count that included users active in
-- the last 61 seconds, but clicking to drill down would show "No results."
-- for users whose last_activity was between 46 and 61 seconds ago.

begin;

-- ============================================================
-- 1. admin_get_dashboard_stats — v_visible_users (45s → 61s)
-- ============================================================
create or replace function public.admin_get_dashboard_stats(p_window text default '24h')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_admin boolean;
  v_window text := lower(btrim(coalesce(p_window, '24h')));
  v_start timestamptz;
  v_step interval;
  v_bucket_trunc text;
  v_series jsonb;

  v_online_users int;
  v_visible_users int;

  v_matches_window int;
  v_messages_window int;
  v_signups_window int;
  v_active_matches_window int;

  v_verification_pending int;
  v_verification_analyzing int;
  v_profile_edits_pending int;
  v_broadcasts_draft int;
  v_broadcasts_scheduled int;
  v_notifications_pending int;
  v_notifications_failed int;

  v_paid_active int;
  v_paid_expiring_7d int;
  v_paid_by_tier jsonb;
  v_earnings_by_currency jsonb;

  v_ai_usage_summary jsonb;
  v_ai_recent_errors jsonb;
  v_edge_functions_summary jsonb;
  v_edge_functions_recent_errors jsonb;

  v_quota_updated_at timestamptz;
  v_quota_providers jsonb;
begin
  select exists (
    select 1
    from public.users u
    where u.id = auth.uid()
      and u.is_admin = true
  )
  into v_is_admin;

  if not coalesce(v_is_admin, false) then
    raise exception 'not authorized';
  end if;

  if v_window not in ('24h', '7d') then
    v_window := '24h';
  end if;

  if v_window = '24h' then
    v_bucket_trunc := 'hour';
    v_step := interval '1 hour';
    v_start := date_trunc('hour', now() - interval '23 hours');
  else
    v_bucket_trunc := 'day';
    v_step := interval '1 day';
    v_start := date_trunc('day', now() - interval '6 days');
  end if;

  v_online_users := coalesce(public.get_online_users_count(auth.uid()), 0);
  select coalesce(count(*), 0)::int
  into v_visible_users
  from public.users u
  join public.user_activity ua on ua.user_id = u.id
  where ua.is_online = true
    and ua.last_activity > now() - interval '61 seconds'
    and coalesce(u.user_visibility_setting, false) = true
    and coalesce(u.system_visibility_status, 'visible') = 'visible';

  select coalesce(count(*), 0)::int
  into v_matches_window
  from public.matches m
  where m.created_at >= v_start;

  select coalesce(count(*), 0)::int
  into v_messages_window
  from public.chat_messages cm
  where cm.created_at >= v_start;

  select coalesce(count(*), 0)::int
  into v_signups_window
  from public.users u
  where u.created_at >= v_start
    and coalesce(u.is_profile_complete, false) = true;

  select coalesce(count(distinct c.match_id), 0)::int
  into v_active_matches_window
  from public.chats c
  where coalesce(c.last_message_at, c.updated_at) >= v_start;

  select coalesce(count(*), 0)::int
  into v_verification_pending
  from public.users u
  where u.verification_status = 'pending';

  select coalesce(count(*), 0)::int
  into v_verification_analyzing
  from public.users u
  where u.verification_status = 'analyzing';

  select coalesce(count(*), 0)::int
  into v_profile_edits_pending
  from public.profile_edit_requests r
  where r.status = 'pending';

  select coalesce(count(*), 0)::int
  into v_broadcasts_draft
  from public.admin_broadcasts b
  where b.status = 'draft';

  select coalesce(count(*), 0)::int
  into v_broadcasts_scheduled
  from public.admin_broadcasts b
  where b.status = 'scheduled';

  select coalesce(count(*), 0)::int
  into v_notifications_pending
  from public.notification_queue nq
  where nq.status = 'pending';

  select coalesce(count(*), 0)::int
  into v_notifications_failed
  from public.notification_queue nq
  where nq.status = 'failed';

  select coalesce(count(*), 0)::int
  into v_paid_active
  from public.users u
  where coalesce(nullif(btrim(coalesce(u.subscription_tier, '')), ''), 'free') <> 'free'
    and u.subscription_expires_at is not null
    and u.subscription_expires_at > now();

  select coalesce(count(*), 0)::int
  into v_paid_expiring_7d
  from public.users u
  where coalesce(nullif(btrim(coalesce(u.subscription_tier, '')), ''), 'free') <> 'free'
    and u.subscription_expires_at is not null
    and u.subscription_expires_at > now()
    and u.subscription_expires_at <= now() + interval '7 days';

  select coalesce(
    (
      select jsonb_object_agg(tier, cnt)
      from (
        select
          coalesce(nullif(btrim(coalesce(u.subscription_tier, '')), ''), 'free') as tier,
          count(*)::int as cnt
        from public.users u
        where coalesce(nullif(btrim(coalesce(u.subscription_tier, '')), ''), 'free') <> 'free'
          and u.subscription_expires_at is not null
          and u.subscription_expires_at > now()
        group by 1
        order by 1
      ) s
    ),
    '{}'::jsonb
  )
  into v_paid_by_tier;

  select coalesce(
    (
      select jsonb_object_agg(currency, total_amount) filter (where total_amount <> 0)
      from (
        select
          coalesce(
            nullif(upper(btrim(coalesce(sq.purchase_metadata ->> 'currency', ''))), ''),
            nullif(upper(btrim(coalesce(sq.purchase_metadata ->> 'currency_code', ''))), ''),
            nullif(upper(btrim(coalesce(sq.purchase_metadata ->> 'currencyCode', ''))), ''),
            'unknown'
          ) as currency,
          sum(
            case
              when sq.purchase_metadata ? 'amount_cents'
                   and (sq.purchase_metadata ->> 'amount_cents') ~ '^-?[0-9]+$'
              then (sq.purchase_metadata ->> 'amount_cents')::numeric / 100
              when sq.purchase_metadata ? 'amount'
                   and (sq.purchase_metadata ->> 'amount') ~ '^-?[0-9]+(\.[0-9]+)?$'
              then (sq.purchase_metadata ->> 'amount')::numeric
              else 0
            end
          ) as total_amount
        from public.user_subscription_queue sq
        where sq.created_at >= (
          case
            when v_window = '7d' then date_trunc('day', now() - interval '7 days')
            else v_start
          end
        )
          and coalesce(nullif(btrim(coalesce(sq.payment_provider, '')), ''), '') <> ''
          and coalesce(lower(btrim(coalesce(sq.status, ''))), '') <> 'cancelled'
        group by 1
        order by 1
      ) s
    ),
    '{}'::jsonb
  )
  into v_earnings_by_currency;

  with buckets as (
    select generate_series(
      v_start,
      date_trunc(v_bucket_trunc, now()),
      v_step
    ) as bucket
  ),
  match_counts as (
    select date_trunc(v_bucket_trunc, m.created_at) as bucket, count(*)::int as c
    from public.matches m
    where m.created_at >= v_start
    group by 1
  ),
  message_counts as (
    select date_trunc(v_bucket_trunc, cm.created_at) as bucket, count(*)::int as c
    from public.chat_messages cm
    where cm.created_at >= v_start
    group by 1
  ),
  signup_counts as (
    select date_trunc(v_bucket_trunc, u.created_at) as bucket, count(*)::int as c
    from public.users u
    where u.created_at >= v_start
      and coalesce(u.is_profile_complete, false) = true
    group by 1
  ),
  active_match_counts as (
    select date_trunc(v_bucket_trunc, coalesce(c.last_message_at, c.updated_at)) as bucket, count(distinct c.match_id)::int as c
    from public.chats c
    where coalesce(c.last_message_at, c.updated_at) >= v_start
    group by 1
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        't', to_char(b.bucket at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'matches', coalesce(mc.c, 0),
        'messages', coalesce(msg.c, 0),
        'signups', coalesce(sc.c, 0),
        'active_matches', coalesce(amc.c, 0)
      )
      order by b.bucket
    ),
    '[]'::jsonb
  )
  into v_series
  from buckets b
  left join match_counts mc on mc.bucket = b.bucket
  left join message_counts msg on msg.bucket = b.bucket
  left join signup_counts sc on sc.bucket = b.bucket
  left join active_match_counts amc on amc.bucket = b.bucket;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'provider', provider,
        'model', model,
        'task', task,
        'calls', calls,
        'failures', failures
      )
      order by calls desc
    ),
    '[]'::jsonb
  )
  into v_ai_usage_summary
  from (
    select
      coalesce(nullif(btrim(coalesce(efi.ai_provider, '')), ''), 'unknown') as provider,
      coalesce(nullif(btrim(coalesce(efi.ai_model, '')), ''), 'unknown') as model,
      coalesce(nullif(btrim(coalesce(efi.ai_task, '')), ''), 'unknown') as task,
      count(*)::int as calls,
      count(*) filter (where efi.success = false)::int as failures
    from public.edge_function_invocations efi
    where efi.invoked_at >= v_start
      and efi.ai_used = true
    group by 1, 2, 3
    order by count(*) desc
    limit 20
  ) s;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        't', to_char(invoked_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'function', function_name,
        'provider', coalesce(nullif(btrim(coalesce(ai_provider, '')), ''), 'unknown'),
        'model', coalesce(nullif(btrim(coalesce(ai_model, '')), ''), 'unknown'),
        'task', coalesce(nullif(btrim(coalesce(ai_task, '')), ''), 'unknown'),
        'request_id', request_id::text,
        'error_type', error_type,
        'error_message', error_message,
        'http_status', http_status
      )
      order by invoked_at desc
    ),
    '[]'::jsonb
  )
  into v_ai_recent_errors
  from (
    select invoked_at, function_name, ai_provider, ai_model, ai_task, request_id, error_type, error_message, http_status
    from public.edge_function_invocations
    where invoked_at >= v_start
      and ai_used = true
      and success = false
    order by invoked_at desc
    limit 25
  ) e;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'function', function_name,
        'calls', calls,
        'failures', failures,
        'last_error_at', case
          when last_error_at is null then null
          else to_char(last_error_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        end
      )
      order by calls desc
    ),
    '[]'::jsonb
  )
  into v_edge_functions_summary
  from (
    select
      efi.function_name,
      count(*)::int as calls,
      count(*) filter (where efi.success = false)::int as failures,
      max(efi.invoked_at) filter (where efi.success = false) as last_error_at
    from public.edge_function_invocations efi
    where efi.invoked_at >= v_start
    group by 1
    order by count(*) desc
    limit 20
  ) s;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        't', to_char(invoked_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'function', function_name,
        'request_id', request_id::text,
        'error_type', error_type,
        'error_message', error_message,
        'http_status', http_status
      )
      order by invoked_at desc
    ),
    '[]'::jsonb
  )
  into v_edge_functions_recent_errors
  from (
    select invoked_at, function_name, request_id, error_type, error_message, http_status
    from public.edge_function_invocations
    where invoked_at >= v_start
      and success = false
    order by invoked_at desc
    limit 25
  ) e;

  select max(updated_at) into v_quota_updated_at
  from public.ai_quota_status;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'provider', provider,
        'updated_at', case
          when provider_updated_at is null then null
          else to_char(provider_updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        end,
        'metrics', metrics
      )
      order by provider
    ),
    '[]'::jsonb
  )
  into v_quota_providers
  from (
    select
      provider,
      max(updated_at) as provider_updated_at,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'metric', metric,
            'window', window_key,
            'used', used,
            'limit', limit_value,
            'unit', unit,
            'status', status,
            'start_time', case
              when start_time is null then null
              else to_char(start_time at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
            end,
            'end_time', case
              when end_time is null then null
              else to_char(end_time at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
            end,
            'updated_at', to_char(updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            'details', details
          )
          order by metric, window_key
        ),
        '[]'::jsonb
      ) as metrics
    from public.ai_quota_status
    group by provider
  ) s;

  return jsonb_build_object(
    'generated_at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'window', v_window,
    'engagement', jsonb_build_object(
      'online_users', v_online_users,
      'visible_users', v_visible_users,
      'matches_created', v_matches_window,
      'messages_sent', v_messages_window,
      'new_users', v_signups_window,
      'active_matches', v_active_matches_window
    ),
    'engagement_series', v_series,
    'operations', jsonb_build_object(
      'verification_pending', v_verification_pending,
      'verification_analyzing', v_verification_analyzing,
      'profile_edits_pending', v_profile_edits_pending,
      'broadcasts_draft', v_broadcasts_draft,
      'broadcasts_scheduled', v_broadcasts_scheduled,
      'notifications_pending', v_notifications_pending,
      'notifications_failed', v_notifications_failed
    ),
    'revenue', jsonb_build_object(
      'paid_active_users', v_paid_active,
      'paid_expiring_7d', v_paid_expiring_7d,
      'paid_by_tier', v_paid_by_tier,
      'earnings_by_currency', v_earnings_by_currency
    ),
    'safety', jsonb_build_object(
      'available', false
    ),
    'ai', jsonb_build_object(
      'usage', v_ai_usage_summary,
      'recent_errors', v_ai_recent_errors,
      'quota_status', jsonb_build_object(
        'updated_at', case
          when v_quota_updated_at is null then null
          else to_char(v_quota_updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        end,
        'providers', v_quota_providers
      )
    ),
    'edge_functions', jsonb_build_object(
      'usage', v_edge_functions_summary,
      'recent_errors', v_edge_functions_recent_errors
    )
  );
end;
$$;

grant execute on function public.admin_get_dashboard_stats(text) to authenticated;

-- ============================================================
-- 2. admin_get_dashboard_drilldown — online/visible (45s → 61s)
-- ============================================================
create or replace function public.admin_get_dashboard_drilldown(
  p_window text default '24h',
  p_metric text default null,
  p_param text default null,
  p_limit integer default 200,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_admin boolean;
  v_window text;
  v_metric text;
  v_param text;
  v_p1 text;
  v_p2 text;
  v_p3 text;
  v_start timestamptz;
  v_limit int;
  v_offset int;
  v_fetch int;
  v_result jsonb;
begin
  select exists (
    select 1
    from public.users u
    where u.id = auth.uid()
      and u.is_admin = true
  ) into v_is_admin;

  if not coalesce(v_is_admin, false) then
    raise exception 'not authorized';
  end if;

  v_window := coalesce(nullif(trim(p_window), ''), '24h');
  if v_window not in ('24h', '7d') then
    v_window := '24h';
  end if;

  v_metric := coalesce(nullif(trim(p_metric), ''), '');
  v_param := nullif(trim(coalesce(p_param, '')), '');
  v_p1 := nullif(trim(split_part(coalesce(v_param, ''), '|', 1)), '');
  v_p2 := nullif(trim(split_part(coalesce(v_param, ''), '|', 2)), '');
  v_p3 := nullif(trim(split_part(coalesce(v_param, ''), '|', 3)), '');

  v_limit := greatest(least(coalesce(p_limit, 200), 500), 1);
  v_offset := greatest(coalesce(p_offset, 0), 0);
  v_fetch := v_limit + 1;

  if v_window = '24h' then
    v_start := date_trunc('hour', now() - interval '23 hours');
  else
    v_start := date_trunc('day', now() - interval '6 days');
  end if;

  if v_metric = 'online_users' then
    with rows as (
      select
        ua.user_id as user_id,
        coalesce(u.name, 'User ' || substring(ua.user_id::text, 1, 8)) as user_name,
        ua.last_activity as last_activity_at
      from public.user_activity ua
      left join public.users u on u.id = ua.user_id
      where ua.is_online = true
        and ua.last_activity > now() - interval '61 seconds'
      order by ua.last_activity desc, ua.user_id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'visible_users' then
    with rows as (
      select
        ua.user_id as user_id,
        coalesce(u.name, 'User ' || substring(ua.user_id::text, 1, 8)) as user_name,
        ua.last_activity as last_activity_at
      from public.user_activity ua
      left join public.users u on u.id = ua.user_id
      where ua.is_online = true
        and ua.last_activity > now() - interval '61 seconds'
        and coalesce(u.user_visibility_setting, false) = true
        and coalesce(u.system_visibility_status, 'visible') = 'visible'
      order by ua.last_activity desc, ua.user_id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'new_users' then
    with rows as (
      select
        u.id as user_id,
        u.name as user_name,
        u.created_at as created_at
      from public.users u
      where u.created_at >= v_start
        and coalesce(u.is_profile_complete, false) = true
      order by u.created_at desc, u.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'messages_sent' then
    with rows as (
      select
        cm.sender_id as user_id,
        u.name as user_name,
        count(*)::int as messages
      from public.chat_messages cm
      left join public.users u on u.id = cm.sender_id
      where cm.created_at >= v_start
      group by cm.sender_id, u.name
      order by count(*) desc, cm.sender_id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'matches_created' then
    with rows as (
      select
        m.id as match_id,
        m.user1_id,
        u1.name as user1_name,
        m.user2_id,
        u2.name as user2_name,
        m.created_at as matched_at,
        m.matched_intent,
        to_jsonb(
          array(
            select x
            from unnest(
              array[
                case when m.match_type = 'proximity' then 'proximity' end,
                case when m.match_type = 'event' then 'event' end,
                'shared_intent',
                case when m.match_type in ('proximity', 'event') then 'shared_interest' end
              ]::text[]
            ) as t(x)
            where x is not null
          )
        ) as basis,
        m.event_id,
        e.event_name
      from public.matches m
      left join public.users u1 on u1.id = m.user1_id
      left join public.users u2 on u2.id = m.user2_id
      left join public.events e on e.id = m.event_id
      where m.created_at >= v_start
      order by m.created_at desc, m.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'active_matches' then
    with recent_match_ids as (
      select
        c.match_id,
        max(coalesce(c.last_message_at, c.updated_at)) as last_activity_at
      from public.chats c
      where coalesce(c.last_message_at, c.updated_at) >= v_start
      group by c.match_id
    ),
    rows as (
      select
        m.id as match_id,
        m.user1_id,
        u1.name as user1_name,
        m.user2_id,
        u2.name as user2_name,
        m.created_at as matched_at,
        r.last_activity_at,
        m.matched_intent,
        to_jsonb(
          array(
            select x
            from unnest(
              array[
                case when m.match_type = 'proximity' then 'proximity' end,
                case when m.match_type = 'event' then 'event' end,
                'shared_intent',
                case when m.match_type in ('proximity', 'event') then 'shared_interest' end
              ]::text[]
            ) as t(x)
            where x is not null
          )
        ) as basis,
        m.event_id,
        e.event_name
      from recent_match_ids r
      join public.matches m on m.id = r.match_id
      left join public.users u1 on u1.id = m.user1_id
      left join public.users u2 on u2.id = m.user2_id
      left join public.events e on e.id = m.event_id
      order by r.last_activity_at desc, m.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'verification_pending' then
    with rows as (
      select
        u.id as user_id,
        u.name as user_name,
        to_char(u.verification_submitted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as verification_submitted_at
      from public.users u
      where u.verification_status = 'pending'
      order by u.verification_submitted_at desc nulls last, u.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'verification_analyzing' then
    with rows as (
      select
        u.id as user_id,
        u.name as user_name,
        to_char(u.verification_submitted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as verification_submitted_at
      from public.users u
      where u.verification_status = 'analyzing'
      order by u.verification_submitted_at desc nulls last, u.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'profile_edits_pending' then
    with rows as (
      select
        r.user_id,
        u.name as user_name,
        to_char(r.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as created_at
      from public.profile_edit_requests r
      left join public.users u on u.id = r.user_id
      where r.status = 'pending'
      order by r.created_at desc, r.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'broadcasts_draft' then
    with rows as (
      select
        b.title,
        b.status,
        to_char(b.scheduled_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as scheduled_at,
        to_char(b.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as created_at
      from public.admin_broadcasts b
      where b.status = 'draft'
      order by b.updated_at desc nulls last, b.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'broadcasts_scheduled' then
    with rows as (
      select
        b.title,
        b.status,
        to_char(b.scheduled_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as scheduled_at,
        to_char(b.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as created_at
      from public.admin_broadcasts b
      where b.status = 'scheduled'
      order by b.scheduled_at desc nulls last, b.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'notifications_pending' then
    with rows as (
      select
        u.name as user_name,
        n.title,
        n.status,
        n.attempts,
        to_char(n.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as created_at
      from public.notification_queue n
      left join public.users u on u.id = n.user_id
      where n.status = 'pending'
      order by n.created_at desc, n.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'notifications_failed' then
    with rows as (
      select
        u.name as user_name,
        n.title,
        n.status,
        n.attempts,
        n.failure_reason,
        to_char(n.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as created_at
      from public.notification_queue n
      left join public.users u on u.id = n.user_id
      where n.status = 'failed'
      order by n.created_at desc, n.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'paid_active_users' then
    with rows as (
      select
        u.id as user_id,
        u.name as user_name,
        u.subscription_tier,
        coalesce(
          (
            select jsonb_object_agg(currency, total_amount)
            from (
              select
                coalesce(
                  nullif(upper(btrim(coalesce(sq.purchase_metadata ->> 'currency', ''))), ''),
                  nullif(upper(btrim(coalesce(sq.purchase_metadata ->> 'currency_code', ''))), ''),
                  'usd'
                ) as currency,
                sum(
                  case
                    when sq.purchase_metadata ? 'amount_cents'
                         and (sq.purchase_metadata ->> 'amount_cents') ~ '^-?[0-9]+$'
                    then (sq.purchase_metadata ->> 'amount_cents')::numeric / 100
                    when sq.purchase_metadata ? 'amount'
                         and (sq.purchase_metadata ->> 'amount') ~ '^-?[0-9]+(\.[0-9]+)?$'
                    then (sq.purchase_metadata ->> 'amount')::numeric
                    else 0
                  end
                ) as total_amount
              from public.user_subscription_queue sq
              where sq.user_id = u.id
                and coalesce(nullif(btrim(coalesce(sq.payment_provider, '')), ''), '') <> ''
                and coalesce(lower(btrim(coalesce(sq.status, ''))), '') <> 'cancelled'
              group by 1
            ) s
          ),
          '{}'::jsonb
        ) as earnings,
        to_char(u.subscription_expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as subscription_expires_at
      from public.users u
      where coalesce(nullif(btrim(coalesce(u.subscription_tier, '')), ''), 'free') <> 'free'
        and u.subscription_expires_at is not null
        and u.subscription_expires_at > now()
      order by u.subscription_expires_at desc, u.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'paid_expiring_7d' then
    with rows as (
      select
        u.id as user_id,
        u.name as user_name,
        u.subscription_tier,
        coalesce(
          (
            select jsonb_object_agg(currency, total_amount)
            from (
              select
                coalesce(
                  nullif(upper(btrim(coalesce(sq.purchase_metadata ->> 'currency', ''))), ''),
                  nullif(upper(btrim(coalesce(sq.purchase_metadata ->> 'currency_code', ''))), ''),
                  'usd'
                ) as currency,
                sum(
                  case
                    when sq.purchase_metadata ? 'amount_cents'
                         and (sq.purchase_metadata ->> 'amount_cents') ~ '^-?[0-9]+$'
                    then (sq.purchase_metadata ->> 'amount_cents')::numeric / 100
                    when sq.purchase_metadata ? 'amount'
                         and (sq.purchase_metadata ->> 'amount') ~ '^-?[0-9]+(\.[0-9]+)?$'
                    then (sq.purchase_metadata ->> 'amount')::numeric
                    else 0
                  end
                ) as total_amount
              from public.user_subscription_queue sq
              where sq.user_id = u.id
                and coalesce(nullif(btrim(coalesce(sq.payment_provider, '')), ''), '') <> ''
                and coalesce(lower(btrim(coalesce(sq.status, ''))), '') <> 'cancelled'
              group by 1
            ) s
          ),
          '{}'::jsonb
        ) as earnings,
        to_char(u.subscription_expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as subscription_expires_at
      from public.users u
      where coalesce(nullif(btrim(coalesce(u.subscription_tier, '')), ''), 'free') <> 'free'
        and u.subscription_expires_at is not null
        and u.subscription_expires_at > now()
        and u.subscription_expires_at <= now() + interval '7 days'
      order by u.subscription_expires_at desc, u.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'paid_by_tier' then
    with rows as (
      select
        u.id as user_id,
        u.name as user_name,
        coalesce(nullif(btrim(coalesce(u.subscription_tier, '')), ''), 'free') as subscription_tier,
        coalesce(
          (
            select jsonb_object_agg(currency, total_amount)
            from (
              select
                coalesce(
                  nullif(upper(btrim(coalesce(sq.purchase_metadata ->> 'currency', ''))), ''),
                  nullif(upper(btrim(coalesce(sq.purchase_metadata ->> 'currency_code', ''))), ''),
                  'usd'
                ) as currency,
                sum(
                  case
                    when sq.purchase_metadata ? 'amount_cents'
                         and (sq.purchase_metadata ->> 'amount_cents') ~ '^-?[0-9]+$'
                    then (sq.purchase_metadata ->> 'amount_cents')::numeric / 100
                    when sq.purchase_metadata ? 'amount'
                         and (sq.purchase_metadata ->> 'amount') ~ '^-?[0-9]+(\.[0-9]+)?$'
                    then (sq.purchase_metadata ->> 'amount')::numeric
                    else 0
                  end
                ) as total_amount
              from public.user_subscription_queue sq
              where sq.user_id = u.id
                and coalesce(nullif(btrim(coalesce(sq.payment_provider, '')), ''), '') <> ''
                and coalesce(lower(btrim(coalesce(sq.status, ''))), '') <> 'cancelled'
              group by 1
            ) s
          ),
          '{}'::jsonb
        ) as earnings,
        to_char(u.subscription_expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as subscription_expires_at
      from public.users u
      where coalesce(nullif(btrim(coalesce(u.subscription_tier, '')), ''), 'free') <> 'free'
        and u.subscription_expires_at is not null
        and u.subscription_expires_at > now()
        and (v_param is null or coalesce(nullif(btrim(coalesce(u.subscription_tier, '')), ''), 'free') = v_param)
      order by u.subscription_expires_at desc, u.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'param', v_param,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'edge_function_usage' then
    with rows as (
      select
        e.function_name,
        to_char(e.invoked_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as invoked_at,
        e.success,
        e.http_status,
        e.duration_ms,
        e.error_type,
        e.error_message,
        e.ai_used,
        e.ai_provider,
        e.ai_model,
        e.ai_task
      from public.edge_function_invocations e
      where e.invoked_at >= v_start
        and (v_param is null or e.function_name = v_param)
      order by e.invoked_at desc, e.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'param', v_param,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  elsif v_metric = 'ai_usage' then
    with rows as (
      select
        to_char(e.invoked_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as invoked_at,
        e.function_name,
        e.ai_provider,
        e.ai_model,
        e.ai_task,
        e.success,
        e.http_status,
        e.duration_ms,
        e.error_type,
        e.error_message
      from public.edge_function_invocations e
      where e.invoked_at >= v_start
        and e.ai_used = true
        and (v_p1 is null or e.ai_provider = v_p1)
        and (v_p2 is null or e.ai_model = v_p2)
        and (v_p3 is null or e.ai_task = v_p3)
      order by e.invoked_at desc, e.id desc
      limit v_fetch
      offset v_offset
    ),
    rows_limited as (
      select * from rows limit v_limit
    ),
    stats as (
      select (count(*) > v_limit) as has_more from rows
    )
    select jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'param', v_param,
      'rows', coalesce((select jsonb_agg(to_jsonb(rows_limited)) from rows_limited), '[]'::jsonb),
      'has_more', coalesce((select has_more from stats), false)
    ) into v_result;
  else
    v_result := jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', '[]'::jsonb,
      'has_more', false
    );
  end if;

  return v_result;
end;
$$;

grant execute on function public.admin_get_dashboard_drilldown(text, text, text, integer, integer) to authenticated;

commit;
