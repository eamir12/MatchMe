-- Sync user_activity online status with user_session changes
-- Handles both logins (session created/activated) and logouts (session revoked/deleted)
-- This ensures real-time online count updates when users log in/out

BEGIN;

-- Create function to sync user_activity based on session changes
CREATE OR REPLACE FUNCTION public.sync_user_activity_on_session_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_is_online boolean;
BEGIN
  -- Determine the user_id and online status based on the operation
  IF TG_OP = 'DELETE' THEN
    v_user_id := OLD.user_id;
    v_is_online := false;
  ELSIF TG_OP = 'INSERT' THEN
    v_user_id := NEW.user_id;
    -- New session = user is online (unless explicitly revoked)
    v_is_online := NOT COALESCE(NEW.revoked, false);
  ELSIF TG_OP = 'UPDATE' THEN
    v_user_id := NEW.user_id;
    -- User is online if session is not revoked
    v_is_online := NOT COALESCE(NEW.revoked, false);
  ELSE
    RETURN NULL;
  END IF;

  -- Update or insert user_activity record
  INSERT INTO public.user_activity (user_id, is_online, last_activity, updated_at)
  VALUES (v_user_id, v_is_online, NOW(), NOW())
  ON CONFLICT (user_id)
  DO UPDATE SET
    is_online = EXCLUDED.is_online,
    last_activity = NOW(),
    updated_at = NOW();

  RETURN NULL; -- AFTER trigger, return value is ignored
END;
$$;

-- Drop existing trigger if exists
DROP TRIGGER IF EXISTS trg_sync_user_activity_on_session_change ON public.user_session;

-- Create trigger on user_session table
CREATE TRIGGER trg_sync_user_activity_on_session_change
  AFTER INSERT OR UPDATE OR DELETE ON public.user_session
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_user_activity_on_session_change();

COMMENT ON FUNCTION public.sync_user_activity_on_session_change() IS 
  'Syncs user_activity.is_online with user_session.revoked status for real-time online count updates';

COMMIT;
