-- Migration: Fix update_user_visibility() referencing non-existent user_activity.last_active_at
--
-- Problem (from postgres_logs):
--   PL/pgSQL function update_user_visibility(uuid) line 21 at RAISE
--   WARNING 01000: Error updating visibility for user <uuid>:
--     column "last_active_at" of relation "user_activity" does not exist
--   Called via PostgREST (authenticator) -> RPC / trigger on users.
--
-- Root cause:
--   The deployed function references user_activity.last_active_at, but that column
--   lives on user_session, not user_activity. user_activity uses last_activity
--   (see 20260220000000_improve_user_status_handling.sql). The EXCEPTION block
--   catches the error and re-raises it as WARNING, so callers succeed but the
--   visibility update is silently skipped -> user_activity.is_visible drifts from
--   users.user_visibility_setting and log spam on every visibility change.
--
-- Fix: redefine with correct columns (last_activity), keeping the safe
-- EXCEPTION -> WARNING pattern so a future schema surprise can't break callers.

-- Ensure is_visible column exists (idempotent, mirrors 20260220 migration)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_activity' AND column_name = 'is_visible'
  ) THEN
    ALTER TABLE public.user_activity ADD COLUMN is_visible BOOLEAN NOT NULL DEFAULT true;
    UPDATE public.user_activity ua
    SET is_visible = COALESCE(u.user_visibility_setting, false)
    FROM public.users u WHERE ua.user_id = u.id;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.update_user_visibility(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  visibility_value BOOLEAN;
BEGIN
  SELECT COALESCE(u.user_visibility_setting, false)
  INTO visibility_value
  FROM public.users u
  WHERE u.id = p_user_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  UPDATE public.user_activity
  SET is_visible = visibility_value,
      updated_at = NOW()
  WHERE user_id = p_user_id;

  IF NOT FOUND THEN
    INSERT INTO public.user_activity (
      user_id,
      last_activity,
      is_online,
      is_visible,
      updated_at
    )
    VALUES (
      p_user_id,
      NOW(),
      false,
      visibility_value,
      NOW()
    )
    ON CONFLICT (user_id) DO UPDATE SET
      is_visible = EXCLUDED.is_visible,
      updated_at = NOW();
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error updating visibility for user %: %', p_user_id, SQLERRM;
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_user_visibility(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_visibility(uuid) TO anon;
