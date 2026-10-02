BEGIN;

ALTER TABLE IF EXISTS public.events
  ADD COLUMN IF NOT EXISTS external_calendar_id text,
  ADD COLUMN IF NOT EXISTS external_event_id text,
  ADD COLUMN IF NOT EXISTS external_provider text,
  ADD COLUMN IF NOT EXISTS is_all_day boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS description text;

COMMIT;
