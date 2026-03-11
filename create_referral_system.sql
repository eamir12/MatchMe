-- Add referral_code and credits to users table
ALTER TABLE users ADD COLUMN IF NOT EXISTS referral_code TEXT UNIQUE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS credits INTEGER DEFAULT 0;

-- Create referrals table
CREATE TABLE IF NOT EXISTS referrals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    referrer_id UUID REFERENCES users(id) ON DELETE CASCADE,
    referee_id UUID REFERENCES users(id) ON DELETE CASCADE UNIQUE,
    status TEXT CHECK (status IN ('pending', 'completed')) DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

-- Index for faster lookups
CREATE INDEX IF NOT EXISTS idx_referrals_referrer ON referrals(referrer_id);
CREATE INDEX IF NOT EXISTS idx_referrals_referee ON referrals(referee_id);
CREATE INDEX IF NOT EXISTS idx_users_referral_code ON users(referral_code);

-- Insert default app_config for referrals
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES
('referral.enabled', 'true', 'boolean', 'referral', 'Master switch to enable/disable the referral system', false),
('referral.reward_amount', '10', 'number', 'referral', 'Amount of credits awarded to both users upon successful referral', false),
('referral.reward_type', '"credits"', 'string', 'referral', 'Type of reward granted (currently only supports credits)', false)
ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value,
    description = EXCLUDED.description;
