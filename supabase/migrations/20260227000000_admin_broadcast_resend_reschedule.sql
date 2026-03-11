BEGIN;

CREATE OR REPLACE FUNCTION public.admin_resend_broadcast_now(
  p_broadcast_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_allowed boolean;
  v_new_broadcast_id uuid;
  v_src public.admin_broadcasts%ROWTYPE;
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
    updated_at
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
    now()
  )
  RETURNING id INTO v_new_broadcast_id;

  BEGIN
    PERFORM public.send_admin_broadcast(v_new_broadcast_id);
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

CREATE OR REPLACE FUNCTION public.admin_reschedule_broadcast(
  p_broadcast_id uuid,
  p_scheduled_at timestamptz
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_allowed boolean;
  v_new_broadcast_id uuid;
  v_src public.admin_broadcasts%ROWTYPE;
  v_scheduled timestamptz;
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

  v_scheduled := p_scheduled_at;
  IF v_scheduled IS NULL THEN
    RAISE EXCEPTION 'p_scheduled_at is required';
  END IF;
  IF v_scheduled <= now() THEN
    RAISE EXCEPTION 'p_scheduled_at must be in the future';
  END IF;

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
    updated_at
  ) VALUES (
    v_src.title,
    v_src.message,
    v_src.message_type,
    v_src.action_url,
    v_src.action_url_text,
    v_scheduled,
    NULL,
    'scheduled',
    v_src.filter_criteria,
    NULL,
    0,
    auth.uid(),
    now(),
    now()
  )
  RETURNING id INTO v_new_broadcast_id;

  RETURN v_new_broadcast_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_resend_broadcast_now(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reschedule_broadcast(uuid, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resend_broadcast_now(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_reschedule_broadcast(uuid, timestamptz) TO service_role;

COMMIT;

