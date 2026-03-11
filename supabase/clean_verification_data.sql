-- =========================================
-- CLEAN VERIFICATION DATA SCRIPT
-- Removes all photo verification attempts to start fresh
-- =========================================

-- 1. Reset verification fields in users table
UPDATE users SET
  is_verified = false,
  verification_photo_path = null,
  verification_status = 'unverified',
  verification_submitted_at = null,
  verification_reviewed_at = null,
  verification_reviewer_id = null,
  verification_similarity_score = null,
  verification_ai_analysis = null,
  verification_auto_rejected = null;

-- 2. Remove all files from verification-photos storage bucket
-- Note: This requires service role permissions
DELETE FROM storage.objects
WHERE bucket_id = 'verification-photos';

-- Optional: Also clean up any old profile photos if needed (uncomment if desired)
-- DELETE FROM storage.objects
-- WHERE bucket_id = 'profile-photos'
-- AND name LIKE '%verification%' OR name LIKE '%temp%';

-- =========================================
-- VERIFICATION STATUS COUNTS (for verification)
-- =========================================

-- Check current verification status
SELECT
  verification_status,
  COUNT(*) as count
FROM users
GROUP BY verification_status
ORDER BY verification_status;

-- Check if any users still have verification data
SELECT
  id,
  email,
  is_verified,
  verification_status,
  verification_photo_path
FROM users
WHERE verification_status != 'unverified'
   OR is_verified = true
   OR verification_photo_path IS NOT NULL;

-- Check storage bucket contents
SELECT
  bucket_id,
  COUNT(*) as files_count
FROM storage.objects
WHERE bucket_id = 'verification-photos'
GROUP BY bucket_id;