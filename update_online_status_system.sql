-- Create a user_activity table to track user online status independently of location updates
-- This allows invisible users to still be counted as online

CREATE TABLE IF NOT EXISTS user_activity (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    last_activity TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    is_online BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create index for performance
CREATE INDEX IF NOT EXISTS idx_user_activity_last_activity ON user_activity(last_activity);
CREATE INDEX IF NOT EXISTS idx_user_activity_is_online ON user_activity(is_online);

-- Enable RLS
ALTER TABLE user_activity ENABLE ROW LEVEL SECURITY;

-- Create policies (idempotent)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Users can manage own activity' AND tablename = 'user_activity'
  ) THEN
    CREATE POLICY "Users can manage own activity" ON user_activity
      FOR ALL USING (auth.uid() = user_id);
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Service role full access' AND tablename = 'user_activity'
  ) THEN
    CREATE POLICY "Service role full access" ON user_activity
      FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');
  END IF;
END;
$$;

-- Update the get_online_users_count function to use user_activity instead of user_locations
CREATE OR REPLACE FUNCTION get_online_users_count(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    online_count INTEGER;
BEGIN
    SET search_path = 'public';

    -- Count users who have been active within the last 30 seconds
    -- This includes both visible and invisible users
    SELECT COUNT(*)
    INTO online_count
    FROM user_activity ua
    WHERE ua.last_activity > NOW() - INTERVAL '30 seconds'
    AND ua.is_online = true;

    RETURN COALESCE(online_count, 0);
END;
$$;

-- Grant proper permissions
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO anon;

-- Create a function to update user activity (call this from your app)
CREATE OR REPLACE FUNCTION update_user_activity(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';

    INSERT INTO user_activity (user_id, last_activity, is_online, updated_at)
    VALUES (p_user_id, NOW(), true, NOW())
    ON CONFLICT (user_id)
    DO UPDATE SET
        last_activity = NOW(),
        is_online = true,
        updated_at = NOW();
END;
$$;

-- Create a function to update user location (call this from mobile apps)
CREATE OR REPLACE FUNCTION update_user_location(
    p_user_id UUID,
    p_latitude DOUBLE PRECISION,
    p_longitude DOUBLE PRECISION,
    p_speed DOUBLE PRECISION DEFAULT NULL,
    p_heading DOUBLE PRECISION DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';

    INSERT INTO user_locations (user_id, latitude, longitude, speed, heading, updated_at)
    VALUES (p_user_id, p_latitude, p_longitude, p_speed, p_heading, NOW())
    ON CONFLICT (user_id)
    DO UPDATE SET
        latitude = EXCLUDED.latitude,
        longitude = EXCLUDED.longitude,
        speed = EXCLUDED.speed,
        heading = EXCLUDED.heading,
        updated_at = NOW();

    -- Also update user activity to keep them online
    PERFORM update_user_activity(p_user_id);
END;
$$;

-- Grant permissions for the location update function
GRANT EXECUTE ON FUNCTION update_user_location(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated;
GRANT EXECUTE ON FUNCTION update_user_location(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO anon;

-- Grant permissions for the update function
GRANT EXECUTE ON FUNCTION update_user_activity(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION update_user_activity(UUID) TO anon;

-- Create a function to mark a user offline immediately (sets is_online = false)
CREATE OR REPLACE FUNCTION set_user_offline(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';

    UPDATE user_activity
    SET is_online = false,
        updated_at = NOW()
    WHERE user_id = p_user_id;

    -- If no row exists, insert one to reflect offline status
    INSERT INTO user_activity (user_id, last_activity, is_online, updated_at)
    SELECT p_user_id, NOW(), false, NOW()
    WHERE NOT EXISTS (SELECT 1 FROM user_activity WHERE user_id = p_user_id);
END;
$$;

GRANT EXECUTE ON FUNCTION set_user_offline(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION set_user_offline(UUID) TO anon;