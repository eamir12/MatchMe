-- Migration: Improve User Status and Visibility Handling
-- Date: 2026-02-20
-- Purpose: Enhance user status tracking with better visibility handling and performance improvements
-- Notes: This migration adds new columns, updates functions, and creates necessary indexes

-- Enable necessary extensions if they don't exist
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Add is_visible column to user_activity if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 
        FROM information_schema.columns 
        WHERE table_name = 'user_activity' 
        AND column_name = 'is_visible'
    ) THEN
        ALTER TABLE user_activity 
        ADD COLUMN is_visible BOOLEAN NOT NULL DEFAULT true;
        
        -- Update existing records to set correct visibility
        UPDATE user_activity ua
        SET is_visible = COALESCE(u.user_visibility_setting, false)
        FROM users u
        WHERE ua.user_id = u.id;
        
        RAISE NOTICE 'Added is_visible column to user_activity and updated existing records';
    END IF;
END $$;

-- Drop existing functions that will be replaced
DROP FUNCTION IF EXISTS public.update_user_activity(uuid);
DROP FUNCTION IF EXISTS public.set_user_offline(uuid);
DROP FUNCTION IF EXISTS public.get_online_users_count(uuid);
DROP FUNCTION IF EXISTS public.get_nearby_users_count(uuid, integer);

-- Create or replace update_user_activity function
CREATE OR REPLACE FUNCTION public.update_user_activity(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    is_visible BOOLEAN;
    is_banned BOOLEAN;
BEGIN
    SET search_path = 'public';
    
    -- Get current visibility and ban status
    SELECT 
        COALESCE(user_visibility_setting, false),
        COALESCE(system_visibility_status, 'visible') = 'banned'
    INTO is_visible, is_banned
    FROM users
    WHERE id = p_user_id;
    
    -- If user is banned, force offline
    IF is_banned THEN
        UPDATE user_activity 
        SET is_online = false, 
            last_activity = NOW(), 
            updated_at = NOW() 
        WHERE user_id = p_user_id;
    ELSE
        -- Update activity with current visibility status
        INSERT INTO user_activity (
            user_id, 
            last_activity, 
            is_online, 
            is_visible,
            updated_at
        )
        VALUES (
            p_user_id, 
            NOW(), 
            true, 
            is_visible,
            NOW()
        )
        ON CONFLICT (user_id) 
        DO UPDATE SET 
            last_activity = NOW(), 
            is_online = true,
            is_visible = EXCLUDED.is_visible,
            updated_at = NOW();
    END IF;
END;
$$;

-- Create or replace set_user_offline function
CREATE OR REPLACE FUNCTION public.set_user_offline(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    
    -- Update existing record if exists
    UPDATE user_activity 
    SET is_online = false, 
        updated_at = NOW() 
    WHERE user_id = p_user_id;
    
    -- Insert if no record exists
    INSERT INTO user_activity (
        user_id, 
        last_activity, 
        is_online, 
        is_visible,
        updated_at
    )
    SELECT 
        p_user_id, 
        NOW(), 
        false, 
        COALESCE(u.user_visibility_setting, false),
        NOW()
    FROM users u
    WHERE u.id = p_user_id
    AND NOT EXISTS (
        SELECT 1 FROM user_activity 
        WHERE user_id = p_user_id
    );
END;
$$;

-- Create update_user_visibility function
CREATE OR REPLACE FUNCTION public.update_user_visibility(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    visibility_value BOOLEAN;
BEGIN
    SET search_path = 'public';
    
    -- Get current visibility setting
    SELECT COALESCE(u.user_visibility_setting, false)
    INTO visibility_value
    FROM users u
    WHERE u.id = p_user_id;
    
    -- Update visibility in user_activity
    UPDATE user_activity
    SET is_visible = visibility_value,
        updated_at = NOW()
    WHERE user_id = p_user_id;
    
    -- If no activity record exists, create one
    IF NOT FOUND THEN
        INSERT INTO user_activity (
            user_id,
            last_activity,
            is_online,
            is_visible,
            updated_at
        )
        VALUES (
            p_user_id,
            NOW(),
            false,  -- Not setting online status here
            visibility_value,
            NOW()
        );
    END IF;
END;
$$;

-- Create or replace get_online_users_count function
CREATE OR REPLACE FUNCTION public.get_online_users_count(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    online_count INTEGER;
BEGIN
    -- Count ALL users who are online (regardless of visibility or location)
    -- Include ALL users including requesting user
    SELECT COUNT(*)
    INTO online_count
    FROM user_activity ua
    WHERE ua.is_online = true
    AND ua.last_activity > NOW() - INTERVAL '10 seconds';

    RETURN COALESCE(online_count, 0);
END;
$$;

-- Create or replace get_nearby_users_count function
CREATE OR REPLACE FUNCTION public.get_nearby_users_count(p_user_id UUID, p_radius_km INTEGER DEFAULT 50)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    nearby_count INTEGER;
    user_lat DOUBLE PRECISION;
    user_lon DOUBLE PRECISION;
BEGIN
    -- Get current user's location
    SELECT latitude, longitude
    INTO user_lat, user_lon
    FROM user_locations
    WHERE user_id = p_user_id
    ORDER BY updated_at DESC
    LIMIT 1;

    -- If user has no location, return 0
    IF user_lat IS NULL OR user_lon IS NULL THEN
        RETURN 0;
    END IF;

    -- Count nearby users who are both online and visible
    SELECT COUNT(DISTINCT ul.user_id)
    INTO nearby_count
    FROM user_locations ul
    JOIN user_activity ua ON ul.user_id = ua.user_id
    JOIN users u ON ul.user_id = u.id
    WHERE ul.user_id != p_user_id
    AND ua.is_online = true
    AND ua.last_activity > NOW() - INTERVAL '10 seconds'
    AND COALESCE(u.user_visibility_setting, false) = true
    AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
    -- Simple bounding box filter for performance
    AND ul.latitude BETWEEN user_lat - (p_radius_km / 111.0) AND user_lat + (p_radius_km / 111.0)
    AND ul.longitude BETWEEN user_lon - (p_radius_km / (111.0 * COS(RADIANS(user_lat)))) 
                         AND user_lon + (p_radius_km / (111.0 * COS(RADIANS(user_lat))))
    AND ul.updated_at > NOW() - INTERVAL '24 hours'; -- Only consider recent locations

    RETURN COALESCE(nearby_count, 0);
END;
$$;

-- Create or replace trigger function for user visibility updates
CREATE OR REPLACE FUNCTION public.trigger_update_user_visibility()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Only trigger on visibility or ban status changes
    IF (OLD.user_visibility_setting IS DISTINCT FROM NEW.user_visibility_setting) OR
       (OLD.system_visibility_status IS DISTINCT FROM NEW.system_visibility_status) THEN
        PERFORM public.update_user_visibility(NEW.id);
    END IF;
    
    RETURN NEW;
END;
$$;

-- Drop trigger if it exists
DROP TRIGGER IF EXISTS trigger_user_visibility_update ON users;

-- Create the trigger
CREATE TRIGGER trigger_user_visibility_update
AFTER UPDATE OF user_visibility_setting, system_visibility_status
ON users
FOR EACH ROW
EXECUTE FUNCTION public.trigger_update_user_visibility();

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_user_activity_online_visible 
ON user_activity (is_online, is_visible) 
WHERE is_online = true AND is_visible = true;

CREATE INDEX IF NOT EXISTS idx_user_activity_last_activity 
ON user_activity (last_activity);

CREATE INDEX IF NOT EXISTS idx_user_locations_updated 
ON user_locations (updated_at);

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION public.update_user_activity(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_activity(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.update_user_visibility(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_visibility(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, integer) TO anon;

-- Update existing user_activity records to ensure they have the correct visibility
DO $$
DECLARE
    user_record RECORD;
BEGIN
    FOR user_record IN SELECT id FROM users LOOP
        PERFORM public.update_user_visibility(user_record.id);
    END LOOP;
END $$;

-- Notify that the migration is complete
