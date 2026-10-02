-- New profiles should start with all matching option toggles enabled.
BEGIN;

ALTER TABLE IF EXISTS public.users
  ADD COLUMN IF NOT EXISTS retro_matching_enabled boolean NOT NULL DEFAULT true,
  ALTER COLUMN background_matching_mode SET DEFAULT true,
  ALTER COLUMN smart_gps_throttling_enabled SET DEFAULT true,
  ALTER COLUMN shared_event_matching_enabled SET DEFAULT true,
  ALTER COLUMN shared_movement_matching_enabled SET DEFAULT true,
  ALTER COLUMN retro_matching_enabled SET DEFAULT true;

COMMIT;