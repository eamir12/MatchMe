-- =============================================================================
-- Follow-up: confirm the new cadence rate, and determine whether the
-- 2026-10-21 02:00 dip (155 runs instead of ~700) was instance-wide downtime
-- or specific to detect-offline-users.
-- One statement, one result set.
-- =============================================================================
WITH per_job AS (
  SELECT COALESCE(to_jsonb(j)->>'jobname', '(unnamed)') AS jobname,
         date_trunc('hour', d.start_time) AS hr,
         count(*)::bigint AS runs
  FROM cron.job_run_details d
  JOIN cron.job j ON j.jobid = d.jobid
  WHERE d.start_time > now() - interval '12 hours'
  GROUP BY 1, 2)

SELECT 'A_per_job_hourly' AS section,
       z.jobname || ' @ ' || z.hr::text AS item,
       z.runs::text AS value,
       '0 = that job did not run in that hour'
FROM (SELECT jobname, hr, runs FROM per_job ORDER BY jobname, hr) z

UNION ALL
SELECT 'B_jobs_missing_an_hour',
       z.jobname || ' @ ' || z.hr::text,
       'MISSING',
       'this job has no rows in that hour'
FROM (SELECT j.jobid, COALESCE(to_jsonb(j)->>'jobname','(unnamed)') AS jobname,
             g.hr
      FROM cron.job j
      CROSS JOIN generate_series(date_trunc('hour', now()) - interval '11 hours',
                                 date_trunc('hour', now()), interval '1 hour') g(hr)
      WHERE NOT EXISTS (SELECT 1 FROM per_job p
                        WHERE p.hr = g.hr AND p.jobname = COALESCE(to_jsonb(j)->>'jobname','(unnamed)'))
      ORDER BY g.hr, 2) z

UNION ALL
SELECT 'C_last_10_runs', z.item, z.value, z.detail
FROM (SELECT 'detect-offline-users @ ' || start_time::text AS item,
             status AS value,
             coalesce(return_message, '') || ' | elapsed=' ||
             round(EXTRACT(EPOCH FROM (end_time - start_time))::numeric, 3)::text || 's' AS detail
      FROM cron.job_run_details
      WHERE jobid IN (SELECT jobid FROM cron.job WHERE jobname = 'detect-offline-users')
      ORDER BY start_time DESC LIMIT 10) z

UNION ALL
SELECT 'D_whole_hour_totals',
       'ALL jobs @ ' || hr::text,
       runs::text,
       'if this dips at 02:00 too, the instance was down'
FROM (SELECT hr, sum(runs)::bigint AS runs FROM per_job GROUP BY 1 ORDER BY 1) z

UNION ALL
SELECT 'E_per_job_per_day',
       z.jobname || ' @ ' || z.d::text,
       z.runs::text,
       'if EVERY job dips on 2026-10-17, the instance was down that day'
FROM (SELECT COALESCE(to_jsonb(j)->>'jobname', '(unnamed)') AS jobname,
             date_trunc('day', d.start_time)::date AS d,
             count(*)::bigint AS runs
      FROM cron.job_run_details d
      JOIN cron.job j ON j.jobid = d.jobid
      WHERE d.start_time > now() - interval '5 days'
      GROUP BY 1, 2
      ORDER BY 1, 2) z
