-- supabase/migrations/20260209000001_add_notification_preferences_to_users.sql
-- Migration: Add notification preferences column to users table
-- Purpose: Store user notification settings in Supabase

BEGIN;

-- Add notification_preferences column to users table if it doesn't exist
ALTER TABLE IF EXISTS public.users
  ADD COLUMN IF NOT EXISTS notification_preferences jsonb DEFAULT '{
    "enable_chat_notifications": true,
    "enable_match_expiry_notifications": true,
    "enable_admin_notifications": true,
    "enable_sound": true,
    "enable_vibration": true,
    "enable_in_app_notifications": true
  }'::jsonb;

-- Create an index on the column for faster queries if needed in the future
CREATE INDEX IF NOT EXISTS idx_users_notification_preferences ON public.users USING gin(notification_preferences);

COMMIT;
