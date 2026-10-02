-- Migration: Pin the cron-jobs schedule in the repo (every minute).
--
-- WHY: cron-jobs drains notification_queue (new matches, match extensions,
-- match/pinned expiry warnings, admin broadcasts, birthday automations, AI
-- quota alerts, profile edit reviews) and runs the matching/expiry tasks.
-- Its invocation schedule lived only in the Supabase Dashboard — it was
-- never version-controlled, and dashboard docs recommended every 15-30
-- minutes, which makes expiry warnings arrive long after they matter and
-- pushes anything-but-immediate.
--
-- This migration schedules the function EVERY MINUTE via pg_cron + pg_net.
--
-- CONFIG STORAGE: the function URL and the shared secret are read from
-- private.cron_job_config — a postgres-only table (schema `private` is not
-- exposed to anon/authenticated, and RLS is enabled with no policies so no
-- other role can read a row even if it reaches the table; pg_cron runs as
-- postgres, the table owner, which bypasses RLS). Neither the URL nor the
-- secret is reachable through the API. The Vault extension is deliberately
-- NOT used because it is not installed on every Supabase project.
--
-- OPERATOR SETUP (one-time, Supabase Dashboard → SQL editor):
--
--   1) Fill in the config (the secret must equal the MATCHME_INTERNAL_SECRET
--      env var configured on the cron-jobs edge function; the anon key is the
--      project's public anon key, sent as the gateway Authorization header
--      because functions deployed with verify_jwt=true reject requests
--      without a valid JWT — the real auth is the internal secret):
--
--        INSERT INTO private.cron_job_config (id, base_url, anon_key, internal_secret)
--        VALUES (1,
--                'https://<PROJECT-REF>.supabase.co',
--                '<ANON_KEY>',
--                '<MATCHME_INTERNAL_SECRET value>')
--        ON CONFLICT (id) DO UPDATE
--          SET base_url = EXCLUDED.base_url,
--              anon_key = EXCLUDED.anon_key,
--              internal_secret = EXCLUDED.internal_secret;
--
--   2) If a manual schedule was previously created in the Dashboard
--      (Integrations → Cron), REMOVE it to avoid duplicate invocations.
--      Duplicate ticks are safe (all tasks are idempotent) but wasteful.
--
-- The schedule name is stable ('matchme-cron-jobs'); re-running this
-- migration updates the command in place (cron.schedule upserts by name).

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Config table, readable only by the table owner (postgres — which is also
-- who pg_cron runs its commands as).
CREATE SCHEMA IF NOT EXISTS private;

CREATE TABLE IF NOT EXISTS private.cron_job_config (
    id INT PRIMARY KEY CHECK (id = 1),
    base_url TEXT NOT NULL,
    anon_key TEXT NOT NULL DEFAULT '',
    internal_secret TEXT NOT NULL DEFAULT ''
);

REVOKE ALL ON SCHEMA private FROM PUBLIC;
REVOKE ALL ON SCHEMA private FROM anon, authenticated;
REVOKE ALL ON private.cron_job_config FROM PUBLIC;
REVOKE ALL ON private.cron_job_config FROM anon, authenticated;

-- RLS with NO policies: anon/authenticated/service_role get zero rows even
-- if they somehow reach the table; postgres (table owner) bypasses RLS and
-- keeps full access, which is exactly what pg_cron runs as.
ALTER TABLE private.cron_job_config ENABLE ROW LEVEL SECURITY;

SELECT cron.schedule(
  'matchme-cron-jobs',
  '* * * * *',
  $$
  SELECT net.http_post(
    url := (
      SELECT base_url || '/functions/v1/cron-jobs'
      FROM private.cron_job_config
      WHERE id = 1
      LIMIT 1
    ),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        SELECT anon_key
        FROM private.cron_job_config
        WHERE id = 1
        LIMIT 1
      ),
      'x-matchme-internal', COALESCE((
        SELECT internal_secret
        FROM private.cron_job_config
        WHERE id = 1
        LIMIT 1
      ), '')
    ),
    body := '{}'::jsonb
  ) AS request_id;
  $$
);

COMMIT;
