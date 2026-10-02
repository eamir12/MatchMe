-- Drop columns that were added in a previous migration but must never exist:
-- location data must only flow through the encrypted broadcast channel, never be stored.
ALTER TABLE location_share_signals DROP COLUMN IF EXISTS status;
ALTER TABLE location_share_signals DROP COLUMN IF EXISTS last_lat;
ALTER TABLE location_share_signals DROP COLUMN IF EXISTS last_lng;
ALTER TABLE location_share_signals DROP COLUMN IF EXISTS last_position_at;
