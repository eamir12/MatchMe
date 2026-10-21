-- Migration: atomic claim of the one-time core onboarding tour.
-- Date: 2026-10-21
-- Depends on: 20262119000000 (users.onboarding_tour_state)
--
-- The core onboarding tour is a ONE-TIME experience for the whole ACCOUNT,
-- not for a device: a member who saw it on one device must never be shown it
-- again on another one. The client (OnboardingIntroService) used to decide
-- this by reading users.onboarding_tour_state and then writing it, which
-- leaves two holes:
--
--   * the read and the write are not atomic — two devices opening the app
--     at the same time could both read "never seen" and both launch the
--     tour;
--   * a device that cannot reach the server cannot tell "never seen" from
--     "seen on another device", and a fail-open answer shows the tour twice.
--
-- This function closes both holes: it takes the row lock, checks the stored
-- state and writes the claim in one atomic step, and it is the only thing
-- that may mark the core tour as consumed.
--
-- Returns true when the caller won the claim (the tour should be launched),
-- false when the account already consumed it. "Seen" is sticky: a claim can
-- never be undone, so a member who saw the tour keeps that fact forever.
--
-- Security: SECURITY DEFINER, but the function only ever reads and writes
-- the calling user's own row (auth.uid()), never anyone else's.
--
-- Idempotent: safe to re-run.

BEGIN;

CREATE OR REPLACE FUNCTION public.claim_onboarding_core_tour()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_state jsonb;
  v_seen_at text;
  v_now text;
BEGIN
  IF v_uid IS NULL THEN
    -- No signed-in account: nothing to claim, nothing to show.
    RETURN false;
  END IF;

  v_now := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');

  -- Lock the row so two devices cannot claim at the same time.
  SELECT onboarding_tour_state INTO v_state
    FROM public.users
   WHERE id = v_uid
     FOR UPDATE;

  v_state := COALESCE(v_state, '{}'::jsonb);
  v_seen_at := NULLIF(BTRIM(v_state ->> 'core_seen_at'), '');

  IF v_seen_at IS NOT NULL THEN
    -- Already consumed on this or on another device.
    RETURN false;
  END IF;

  v_state := jsonb_set(v_state, '{version}', to_jsonb(2), true);
  v_state := jsonb_set(v_state, '{core_seen_at}', to_jsonb(v_now), true);

  UPDATE public.users
     SET onboarding_tour_state = v_state
   WHERE id = v_uid;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.claim_onboarding_core_tour() TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_onboarding_core_tour() TO service_role;

COMMENT ON FUNCTION public.claim_onboarding_core_tour() IS
  'Atomically claims the one-time core onboarding tour for the calling user. Returns true when the caller won the claim and the tour should be launched, false when the account already consumed it.';

COMMIT;
