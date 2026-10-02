-- Per-click idempotency for the Admin "Resend" action.
--
-- Replaces the previous cooldown-guard draft. Requirement: admins may resend
-- the same broadcast as many times as they want in succession; the system must
-- push EXACTLY ONE notification per Resend click — never two for a single
-- click (duplicated invocation / request replay) and never zero.
--
-- Mechanism:
--   * admin_resend_broadcast_now(p_broadcast_id uuid, p_request_id text)
--     p_request_id is a client-generated nonce identifying ONE logical click.
--     If a copy already exists for that nonce + source broadcast, the function
--     returns that copy's id and does NOT send anything again (idempotent
--     replay). A different nonce always creates a fresh copy and sends once.
--   * A partial UNIQUE index makes the dedup race-proof: if two identical
--     invocations arrive concurrently, the loser hits unique_violation and
--     returns the winner's copy instead of creating a second broadcast.
--   * No time-based blocking. Successive resends are always allowed.
--
-- Safe to (re)apply on top of the earlier cooldown draft: the cooldown config
-- is removed and the function is redefined back to non-blocking behavior.

BEGIN;

-- 1) Ancestry + request nonce columns.
ALTER TABLE public.admin_broadcasts
  ADD COLUMN IF NOT EXISTS resend_source_broadcast_id UUID
  REFERENCES public.admin_broadcasts(id) ON DELETE SET NULL;

ALTER TABLE public.admin_broadcasts
  ADD COLUMN IF NOT EXISTS resend_request_id TEXT;

DROP INDEX IF EXISTS idx_admin_broadcasts_resend_source;
CREATE INDEX idx_admin_broadcasts_resend_source
  ON public.admin_broadcasts (resend_source_broadcast_id, created_at)
  WHERE resend_source_broadcast_id IS NOT NULL;

-- Exactly one copy per nonce (race-proof idempotency key).
DROP INDEX IF EXISTS idx_admin_broadcasts_resend_request_unique;
CREATE UNIQUE INDEX idx_admin_broadcasts_resend_request_unique
  ON public.admin_broadcasts (resend_request_id)
  WHERE resend_request_id IS NOT NULL;

-- 2) Drop any leftover cooldown guard config (resends are unlimited now).
DELETE FROM public.app_config
WHERE config_key = 'notifications.admin_broadcast_resend_cooldown_minutes';

-- 3) Resend-now with per-click idempotency (no cooldown).
DROP FUNCTION IF EXISTS public.admin_resend_broadcast_now(uuid);

CREATE OR REPLACE FUNCTION public.admin_resend_broadcast_now(
  p_broadcast_id uuid,
  p_request_id text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_allowed boolean;
  v_new_broadcast_id uuid;
  v_existing_id uuid;
  v_src public.admin_broadcasts%ROWTYPE;
  v_request_key text;
BEGIN
  IF auth.role() = 'service_role' THEN
    v_is_allowed := true;
  ELSE
    SELECT EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = true
    ) INTO v_is_allowed;
  END IF;

  IF NOT COALESCE(v_is_allowed, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_request_key := NULLIF(btrim(COALESCE(p_request_id, '')), '');

  SELECT *
  INTO v_src
  FROM public.admin_broadcasts b
  WHERE b.id = p_broadcast_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Broadcast not found';
  END IF;

  IF COALESCE(v_src.status, '') <> 'sent' THEN
    RAISE EXCEPTION 'broadcast must be sent';
  END IF;

  -- Idempotent replay: same nonce + same source = the SAME logical click.
  -- Return the already-created copy instead of re-sending.
  IF v_request_key IS NOT NULL THEN
    SELECT c.id
    INTO v_existing_id
    FROM public.admin_broadcasts c
    WHERE c.resend_source_broadcast_id = p_broadcast_id
      AND c.resend_request_id = v_request_key;

    IF FOUND THEN
      RETURN v_existing_id;
    END IF;
  END IF;

  BEGIN
    INSERT INTO public.admin_broadcasts (
      title,
      message,
      message_type,
      action_url,
      action_url_text,
      scheduled_at,
      sent_at,
      status,
      filter_criteria,
      target_user_count,
      actual_sent_count,
      created_by,
      created_at,
      updated_at,
      resend_source_broadcast_id,
      resend_request_id
    ) VALUES (
      v_src.title,
      v_src.message,
      v_src.message_type,
      v_src.action_url,
      v_src.action_url_text,
      NULL,
      NULL,
      'draft',
      v_src.filter_criteria,
      NULL,
      0,
      auth.uid(),
      now(),
      now(),
      p_broadcast_id,
      v_request_key
    )
    RETURNING id INTO v_new_broadcast_id;
  EXCEPTION WHEN unique_violation THEN
    -- A concurrent duplicate of the same click won the race; reuse its copy.
    SELECT c.id
    INTO v_existing_id
    FROM public.admin_broadcasts c
    WHERE c.resend_source_broadcast_id = p_broadcast_id
      AND c.resend_request_id = v_request_key;

    IF FOUND THEN
      RETURN v_existing_id;
    END IF;
    RAISE;
  END;

  BEGIN
    PERFORM public.send_admin_broadcast(v_new_broadcast_id, 20000, 0);
  EXCEPTION WHEN OTHERS THEN
    UPDATE public.admin_broadcasts
    SET status = 'failed',
        updated_at = now()
    WHERE id = v_new_broadcast_id;
    RAISE;
  END;

  RETURN v_new_broadcast_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_resend_broadcast_now(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resend_broadcast_now(uuid, text) TO service_role;

COMMIT;