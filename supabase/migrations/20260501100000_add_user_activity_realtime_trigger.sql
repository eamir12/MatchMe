-- Migration: Add Real-time Trigger for User Activity Changes
-- Date: 2026-05-01
-- Purpose: Ensure admin dashboard updates immediately when users log off
-- Details: When user_activity is updated (e.g., user logs off), trigger admin_dashboard_tick
--          so the admin dashboard's realtime subscription receives the update

BEGIN;

-- Add trigger to touch admin_dashboard_tick when user_activity changes
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='user_activity') THEN
    DROP TRIGGER IF EXISTS trg_touch_admin_dashboard_tick_user_activity ON public.user_activity;
    CREATE TRIGGER trg_touch_admin_dashboard_tick_user_activity
      AFTER INSERT OR UPDATE OR DELETE ON public.user_activity
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.touch_admin_dashboard_tick();
  END IF;
END $$;

COMMIT;
