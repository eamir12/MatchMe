-- ============================================================================
-- Fix: edge_internal_secret was readable by every client.
--
-- Found by the Oct 7 secret-leak audit: the shared secret used to authenticate
-- edge-function -> DB RPC calls (edge_update_verification,
-- cleanup_expired_verification_photos) was stored as a plain app_config row.
-- app_config SELECT is open to anon+authenticated and is served wholesale to
-- clients by the public-reference-data edge function and the app_config
-- realtime stream — so ANY app user could read the secret and then call
-- edge_update_verification() themselves to tamper with verification data.
--
-- Remediation in this migration:
--   1. New owner-only table public.edge_internal_secrets (RLS enabled, zero
--      policies, no grants to anon/authenticated) — invisible to clients.
--   2. A FRESH secret value generated server-side (the old value must be
--      treated as compromised — rotate by copying the new value into the
--      EDGE_INTERNAL_SECRET edge secret, see steps below).
--   3. edge_require_internal_secret() rewritten to read the new table
--      instead of app_config (both callers go through this one function).
--   4. The app_config row deleted.
--   5. anon SELECT policies on app_config dropped (authenticated keep
--      access — the client config fetch and realtime stream need it; anon
--      never legitimately reads config).
--
-- AFTER RUNNING:
--   a. SELECT secret FROM public.edge_internal_secrets WHERE name = 'edge_internal_secret';
--      (copy the value — shown only to you, in your SQL editor session)
--   b. Supabase Dashboard -> Edge Functions -> Secrets: set
--      EDGE_INTERNAL_SECRET to that value.
--   c. Test the admin photo-verification flow (that is the flow that calls
--      edge_update_verification through compare-verification-photos).
--
-- Idempotent: re-running keeps the existing generated secret (ON CONFLICT DO
-- NOTHING), so it never silently rotates a value you already copied.
-- ============================================================================

BEGIN;

-- 1. Owner-only secret table
CREATE TABLE IF NOT EXISTS public.edge_internal_secrets (
  name   text PRIMARY KEY,
  secret text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  rotated_at timestamptz
);

ALTER TABLE public.edge_internal_secrets ENABLE ROW LEVEL SECURITY;
-- No policies created: RLS denies anon/authenticated automatically, and the
-- table owner (postgres, i.e. SECURITY DEFINER functions) bypasses RLS.
REVOKE ALL ON public.edge_internal_secrets FROM anon;
REVOKE ALL ON public.edge_internal_secrets FROM authenticated;

-- 2. Fresh secret (64 hex chars). ON CONFLICT DO NOTHING = idempotent.
INSERT INTO public.edge_internal_secrets (name, secret)
VALUES (
  'edge_internal_secret',
  replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
)
ON CONFLICT (name) DO NOTHING;

-- 3. Rewrite the verifier to read the new table
CREATE OR REPLACE FUNCTION public.edge_require_internal_secret()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_headers  jsonb;
  v_provided text;
  v_expected text;
BEGIN
  v_headers := COALESCE(current_setting('request.headers', true), '{}'::text)::jsonb;
  v_provided := COALESCE(
    v_headers ->> 'x-edge-internal-secret',
    v_headers ->> 'X-Edge-Internal-Secret'
  );

  SELECT secret INTO v_expected
  FROM public.edge_internal_secrets
  WHERE name = 'edge_internal_secret'
  LIMIT 1;

  IF v_expected IS NULL OR btrim(v_expected) = '' THEN
    RAISE EXCEPTION 'edge_internal_secret_not_configured';
  END IF;

  IF v_provided IS NULL OR v_provided <> v_expected THEN
    RAISE EXCEPTION 'edge_internal_secret_invalid';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.edge_require_internal_secret() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.edge_require_internal_secret() TO authenticated;

-- 4. Remove the exposed copy
DELETE FROM public.app_config WHERE config_key = 'edge_internal_secret';

-- 5. Drop anon SELECT policies on app_config (keep authenticated ones)
DO $$
DECLARE
  pol record;
BEGIN
  FOR pol IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'app_config'
      AND cmd IN ('SELECT', 'ALL')
      AND 'anon'::text = ANY (roles::text[])
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.app_config', pol.policyname);
  END LOOP;
END $$;

COMMIT;
