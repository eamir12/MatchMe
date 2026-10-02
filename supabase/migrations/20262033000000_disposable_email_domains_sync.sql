-- Disposable email domains sync infrastructure
-- Server-side overlay for the static blocklists bundled in the app/edge functions.
-- cron-jobs refreshes this table from the community blocklist (guarded by
-- disposable_email.sync_interval_minutes); secure-sign-up checks it on the hot path.

-- ---------------------------------------------------------------------------
-- app_config keys
-- ---------------------------------------------------------------------------
INSERT INTO public.app_config (
  config_key,
  config_value,
  config_type,
  category,
  description,
  is_user_configurable,
  min_value,
  max_value
) VALUES
  (
    'disposable_email.sync_enabled',
    'true'::jsonb,
    'boolean',
    'security',
    'Enable scheduled backend refresh of the disposable email domains blocklist.',
    false,
    null,
    null
  ),
  (
    'disposable_email.sync_interval_minutes',
    '1440'::jsonb,
    'number',
    'security',
    'Minimum minutes between successful disposable email blocklist refreshes.',
    false,
    60,
    10080
  ),
  (
    'disposable_email.sync_timeout_ms',
    '15000'::jsonb,
    'number',
    'security',
    'HTTP timeout in milliseconds for the blocklist source request.',
    false,
    3000,
    60000
  ),
  (
    'disposable_email.sync_source_url',
    '"https://raw.githubusercontent.com/disposable-email-domains/disposable-email-domains/main/disposable_email_blocklist.conf"'::jsonb,
    'string',
    'security',
    'Plain-text source (one domain per line) for the disposable email blocklist sync.',
    false,
    null,
    null
  )
ON CONFLICT (config_key) DO UPDATE
SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

-- ---------------------------------------------------------------------------
-- Blocklist table (public data: domain names of temp-mail providers, no PII)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.disposable_email_domains (
  domain text PRIMARY KEY,
  source text NOT NULL DEFAULT 'community-blocklist',
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.disposable_email_domains ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS disposable_email_domains_public_read
  ON public.disposable_email_domains;
CREATE POLICY disposable_email_domains_public_read
  ON public.disposable_email_domains
  FOR SELECT
  USING (true);

GRANT SELECT ON TABLE public.disposable_email_domains TO anon, authenticated;
GRANT ALL ON TABLE public.disposable_email_domains TO service_role;

-- ---------------------------------------------------------------------------
-- Sync state singleton (id always 1)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.disposable_email_sync_state (
  id integer PRIMARY KEY CHECK (id = 1),
  last_sync_at timestamptz,
  last_count integer,
  last_source text,
  last_error text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.disposable_email_sync_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS disposable_email_sync_state_public_read
  ON public.disposable_email_sync_state;
CREATE POLICY disposable_email_sync_state_public_read
  ON public.disposable_email_sync_state
  FOR SELECT
  USING (true);

GRANT SELECT ON TABLE public.disposable_email_sync_state TO anon, authenticated;
GRANT ALL ON TABLE public.disposable_email_sync_state TO service_role;

-- Seed: reported temp-mail domain that providers missed. Kept as source='custom'
-- so the prune step never removes it.
INSERT INTO public.disposable_email_domains (domain, source)
VALUES ('jobscai.com', 'custom')
ON CONFLICT (domain) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Batch upsert (called by cron-jobs with service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.upsert_disposable_email_domains_batch(
  p_domains text[],
  p_source text DEFAULT 'community-blocklist'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_source text := NULLIF(btrim(COALESCE(p_source, '')), '');
  v_domain text;
  v_count integer := 0;
BEGIN
  IF v_source IS NULL THEN
    RAISE EXCEPTION 'p_source is required';
  END IF;

  IF p_domains IS NULL OR array_length(p_domains, 1) IS NULL THEN
    RETURN 0;
  END IF;

  FOREACH v_domain IN ARRAY p_domains
  LOOP
    v_domain := lower(btrim(v_domain));
    CONTINUE WHEN v_domain IS NULL OR v_domain = '';
    CONTINUE WHEN length(v_domain) > 253;
    CONTINUE WHEN v_domain !~ '^[a-z0-9]([a-z0-9.-]{0,61}[a-z0-9])?\.[a-z]{2,}$';

    INSERT INTO public.disposable_email_domains (domain, source, last_seen_at)
    VALUES (v_domain, v_source, now())
    ON CONFLICT (domain) DO UPDATE
    SET
      last_seen_at = now();

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_disposable_email_domains_batch(text[], text)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.upsert_disposable_email_domains_batch(text[], text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Prune community rows no longer present in the source.
-- Custom rows (e.g. manually reported domains) are never pruned.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prune_disposable_email_domains(
  p_older_than timestamptz
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted integer := 0;
BEGIN
  DELETE FROM public.disposable_email_domains
  WHERE source = 'community-blocklist'
    AND last_seen_at < p_older_than;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_disposable_email_domains(timestamptz)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.prune_disposable_email_domains(timestamptz)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Hot-path membership check for secure-sign-up (service_role only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_disposable_email_domain(p_domain text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_domain IS NULL OR btrim(p_domain) = '' THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.disposable_email_domains
    WHERE domain = lower(btrim(p_domain))
  );
END;
$$;

REVOKE ALL ON FUNCTION public.is_disposable_email_domain(text)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.is_disposable_email_domain(text)
  TO service_role;
