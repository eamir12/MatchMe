-- supabase/migrations/20260320000000_add_missing_user_settings_columns.sql
-- Migration: Add missing user settings columns to users table
-- Purpose: Ensure all settings from the Settings screen can be synced with Supabase

BEGIN;

-- Add missing scalar columns for user preferences
ALTER TABLE IF EXISTS public.users
  ADD COLUMN IF NOT EXISTS preferred_language text DEFAULT 'en',
  ADD COLUMN IF NOT EXISTS unit_system text DEFAULT 'system',
  ADD COLUMN IF NOT EXISTS time_format text DEFAULT 'system',
  ADD COLUMN IF NOT EXISTS theme_mode text DEFAULT 'system',
  ADD COLUMN IF NOT EXISTS high_accuracy_mode boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS match_radius_default integer DEFAULT 50,
  ADD COLUMN IF NOT EXISTS gps_interval_default integer DEFAULT 5,
  ADD COLUMN IF NOT EXISTS smart_gps_throttling_enabled boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS shared_event_matching_enabled boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS shared_movement_matching_enabled boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS strict_gender_age_enforcement boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS active_modes jsonb DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS languages_known jsonb DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS gender_preferences jsonb DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS age_preferences jsonb DEFAULT '{}'::jsonb;

-- Create indexes for commonly queried settings columns
CREATE INDEX IF NOT EXISTS idx_users_preferred_language ON public.users (preferred_language);
CREATE INDEX IF NOT EXISTS idx_users_unit_system ON public.users (unit_system);
CREATE INDEX IF NOT EXISTS idx_users_time_format ON public.users (time_format);
CREATE INDEX IF NOT EXISTS idx_users_theme_mode ON public.users (theme_mode);
CREATE INDEX IF NOT EXISTS idx_users_high_accuracy_mode ON public.users (high_accuracy_mode);
CREATE INDEX IF NOT EXISTS idx_users_match_radius_default ON public.users (match_radius_default);
CREATE INDEX IF NOT EXISTS idx_users_gps_interval_default ON public.users (gps_interval_default);

-- Create GIN indexes for JSONB columns that may be queried
CREATE INDEX IF NOT EXISTS idx_users_gender_preferences ON public.users USING gin(gender_preferences);
CREATE INDEX IF NOT EXISTS idx_users_age_preferences ON public.users USING gin(age_preferences);
CREATE INDEX IF NOT EXISTS idx_users_active_modes ON public.users USING gin(active_modes);
CREATE INDEX IF NOT EXISTS idx_users_languages_known ON public.users USING gin(languages_known);

COMMIT;
