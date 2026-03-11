-- Add device_id to referrals table for abuse prevention
ALTER TABLE referrals ADD COLUMN IF NOT EXISTS device_id TEXT;

-- Index for fast abuse checks
CREATE INDEX IF NOT EXISTS idx_referrals_device_id ON referrals(device_id);

-- (Optional) If you already created the other table and want to clean up:
-- DROP TABLE IF EXISTS referral_device_claims;
