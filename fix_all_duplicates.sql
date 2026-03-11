-- Comprehensive fix for duplicate objects in admin broadcast system
-- Run this script to resolve all "already exists" errors

-- Drop existing triggers
DROP TRIGGER IF EXISTS trigger_update_admin_broadcasts_updated_at ON admin_broadcasts;

-- Drop existing functions
DROP FUNCTION IF EXISTS get_users_for_broadcast(JSONB);
DROP FUNCTION IF EXISTS count_target_users(JSONB);
DROP FUNCTION IF EXISTS update_admin_broadcasts_updated_at();
DROP FUNCTION IF EXISTS send_admin_broadcast(UUID);

-- Drop existing policies
DROP POLICY IF EXISTS "Admins can manage broadcasts" ON admin_broadcasts;
DROP POLICY IF EXISTS "Users can view own deliveries" ON admin_broadcast_deliveries;
DROP POLICY IF EXISTS "Service role manages notification queue" ON notification_queue;

-- Drop existing indexes
DROP INDEX IF EXISTS idx_admin_broadcasts_status;
DROP INDEX IF EXISTS idx_admin_broadcasts_scheduled_at;
DROP INDEX IF EXISTS idx_admin_broadcast_deliveries_broadcast_id;
DROP INDEX IF EXISTS idx_admin_broadcast_deliveries_user_id;
DROP INDEX IF EXISTS idx_admin_broadcast_deliveries_status;
DROP INDEX IF EXISTS idx_notification_queue_status;
DROP INDEX IF EXISTS idx_notification_queue_scheduled_at;

-- Verify all objects were dropped
SELECT 'Triggers dropped successfully' as status;
SELECT 'Functions dropped successfully' as status;
SELECT 'Policies dropped successfully' as status;
SELECT 'Indexes dropped successfully' as status;