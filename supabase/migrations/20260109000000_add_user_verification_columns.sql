-- Add user verification columns to users table
-- This migration adds fields to support photo-based user verification

ALTER TABLE users ADD COLUMN IF NOT EXISTS is_verified BOOLEAN DEFAULT FALSE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS verification_photo_path TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS verification_status TEXT DEFAULT 'unverified' CHECK (verification_status IN ('unverified', 'analyzing', 'pending', 'approved', 'rejected'));
ALTER TABLE users ADD COLUMN IF NOT EXISTS verification_submitted_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS verification_reviewed_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS verification_reviewer_id UUID REFERENCES auth.users(id);

-- AI comparison fields
ALTER TABLE users ADD COLUMN IF NOT EXISTS verification_similarity_score DECIMAL(3,2); -- 0.00 to 1.00
ALTER TABLE users ADD COLUMN IF NOT EXISTS verification_ai_analysis JSONB; -- Store detailed AI analysis results
ALTER TABLE users ADD COLUMN IF NOT EXISTS verification_auto_rejected BOOLEAN DEFAULT FALSE; -- Auto-rejected due to low similarity

-- Add index for efficient querying of pending verifications
CREATE INDEX IF NOT EXISTS idx_users_verification_status ON users(verification_status) WHERE verification_status = 'pending';

-- Add comment for documentation
COMMENT ON COLUMN users.is_verified IS 'Whether the user has been verified through photo verification';
COMMENT ON COLUMN users.verification_photo_path IS 'Supabase storage path to the verification photo';
COMMENT ON COLUMN users.verification_status IS 'Current status of verification: unverified, pending, approved, rejected';
COMMENT ON COLUMN users.verification_submitted_at IS 'When the verification was submitted';
COMMENT ON COLUMN users.verification_reviewed_at IS 'When the verification was reviewed';
COMMENT ON COLUMN users.verification_reviewer_id IS 'ID of the admin who reviewed the verification';
COMMENT ON COLUMN users.verification_similarity_score IS 'AI-calculated similarity score between profile photo and verification photo (0.00-1.00)';
COMMENT ON COLUMN users.verification_ai_analysis IS 'Detailed AI analysis results from face comparison';
COMMENT ON COLUMN users.verification_auto_rejected IS 'Whether verification was automatically rejected due to low similarity score';