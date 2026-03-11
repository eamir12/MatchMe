ALTER TABLE users
ADD COLUMN IF NOT EXISTS approved_primary_photos JSONB DEFAULT '[]'::jsonb;

COMMENT ON COLUMN users.approved_primary_photos IS 'List of photo object paths approved as primary photos';
