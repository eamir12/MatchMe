-- Migration: Fix Deleted User Handling in Activity & Location Updates
-- Date: 2026-04-13
-- Purpose: Gracefully handle when deleted or non-existent users try to update their activity or location
-- Issues Fixed:
--   1. "null value in column \"is_visible\" violates not-null constraint" when user is deleted
--   2. Foreign key constraint violation when trying to update location for deleted user

-- Drop and recreate update_user_activity to handle missing users
DROP FUNCTION IF EXISTS public.update_user_activity(uuid);

CREATE OR REPLACE FUNCTION public.update_user_activity(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    is_visible BOOLEAN;
    is_banned BOOLEAN;
    user_exists BOOLEAN;
BEGIN
    SET search_path = 'public';
    
    -- Check if user exists in the users table
    SELECT EXISTS(SELECT 1 FROM users WHERE id = p_user_id)
    INTO user_exists;
    
    -- If user doesn't exist (has been deleted), return early silently
    -- This prevents NULL constraint violations on is_visible
    IF NOT user_exists THEN
        RETURN;
    END IF;
    
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

-- Drop and recreate update_user_location to handle missing users
DROP FUNCTION IF EXISTS public.update_user_location(uuid, double precision, double precision, double precision, double precision);

CREATE OR REPLACE FUNCTION public.update_user_location(
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
DECLARE
    user_exists BOOLEAN;
BEGIN
    SET search_path = 'public';

    -- Check if user still exists before attempting any updates
    -- This prevents foreign key constraint violations on deleted users
    SELECT EXISTS(SELECT 1 FROM users WHERE id = p_user_id)
    INTO user_exists;
    
    IF NOT user_exists THEN
        -- User has been deleted; silently return to avoid errors
        -- The user_locations record will be cascade-deleted when user was deleted
        RETURN;
    END IF;

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

-- Update set_user_offline to also handle missing users gracefully
DROP FUNCTION IF EXISTS public.set_user_offline(uuid);

CREATE OR REPLACE FUNCTION public.set_user_offline(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    user_exists BOOLEAN;
BEGIN
    SET search_path = 'public';
    
    -- Check if user exists before attempting update
    SELECT EXISTS(SELECT 1 FROM users WHERE id = p_user_id)
    INTO user_exists;
    
    IF NOT user_exists THEN
        -- User has been deleted; silently return
        RETURN;
    END IF;
    
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
    ON CONFLICT (user_id)
    DO UPDATE SET
        is_online = false,
        updated_at = NOW();
END;
$$;
