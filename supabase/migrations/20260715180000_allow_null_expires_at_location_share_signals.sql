-- Allow NULL expires_at for "Until Turned Off" location sharing
ALTER TABLE location_share_signals
  ALTER COLUMN expires_at DROP NOT NULL;
