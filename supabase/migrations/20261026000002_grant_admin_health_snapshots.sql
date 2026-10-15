-- Fix: the health_sampler task inside cron-jobs could SELECT
-- admin_health_snapshots (its cadence gate succeeded) but INSERT failed
-- with "permission denied for table admin_health_snapshots" — this
-- project's default privileges do not cover the new table for service_role.
-- Explicit grants, idempotent. RLS remains enabled; the service_role
-- policy plus these grants permit sampler writes, and the authenticated
-- INSERT grant is still constrained by the socket-only + is_admin policy.
-- Reads continue to go through the SECURITY DEFINER RPC only.

GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.admin_health_snapshots
  TO service_role;

GRANT INSERT
  ON public.admin_health_snapshots
  TO authenticated;
