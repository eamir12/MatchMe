-- Fix: admin broadcasts reported "sent" while delivering 0 notifications.
--
-- Root cause (confirmed via production data):
--   send_admin_broadcast applies a 2-broadcast/24h frequency guard
--   (20260916000000_add_notification_limits.sql) but the surrounding logic did
--   not account for it:
--     * count_target_users (the Admin-confirm dialog) ignored the guard, so
--       admins were shown N targets while 0 were actually pushed.
--     * the final-chunk test used DELIVERED count instead of SCANNED rows; any
--       run that delivered 0 was still flipped to status='sent' with 0/0 counts.
--     * skipped users were never persisted.
--     * cron advanced its chunk offset by the delivered count, so guarded
--       batches lost their tail users.
--     * admin_resend_broadcast_now called the single-arg send_admin_broadcast
--       overload that 20260916000000 dropped (resend-now errored and marked the
--       new copy failed).
--
-- Changes:
--   1. admin_broadcasts.skipped_count column records guard-limited users.
--   2. Status CHECK gains 'cancelled' for zero-delivery broadcasts
--      (never a fake 'sent').
--   3. count_target_users applies the same frequency guard as the sender so the
--      confirm dialog shows the true deliverable audience.
--   4. send_admin_broadcast tracks scanned vs delivered rows, uses scanned rows
--      for final-chunk detection, flips to 'cancelled' when the final chunk
--      delivered 0, accumulates skipped_count, and returns scanned_count so
--      cron paginates correctly.
--   5. admin_resend_broadcast_now calls the 3-arg send overload.
--   6. New UI translations seeded (cancelled status / skipped count).

BEGIN;

-- 1) Persist how many eligible users the frequency guard skipped.
ALTER TABLE public.admin_broadcasts
  ADD COLUMN IF NOT EXISTS skipped_count INTEGER DEFAULT 0;

-- Speed up the per-user frequency guard (search by user + recency).
CREATE INDEX IF NOT EXISTS idx_notification_queue_user_created
  ON public.notification_queue (user_id, created_at);

-- 2) Allow 'cancelled' status (zero-delivery broadcast). Replace the old check
--    constraint (named inline by Postgres, so match by definition text).
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.admin_broadcasts'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%status%'
  LOOP
    EXECUTE format('ALTER TABLE public.admin_broadcasts DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;

ALTER TABLE public.admin_broadcasts
  ADD CONSTRAINT admin_broadcasts_status_check
  CHECK (status IN ('draft', 'scheduled', 'sending', 'sent', 'failed', 'cancelled'));

-- 3) count_target_users now applies the exact same frequency guard the sender
--    uses, so the Admin confirm dialog shows what will actually be delivered.
CREATE OR REPLACE FUNCTION public.count_target_users(filter_criteria jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_allowed boolean;
  user_count integer;
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

  -- Exclude users who already queued 2 admin broadcasts in the last 24h.
  SELECT COUNT(*)
  INTO user_count
  FROM (
    SELECT g.user_id
    FROM public.get_users_for_broadcast(filter_criteria) g
    WHERE (
      SELECT COUNT(*) FROM public.notification_queue q
      WHERE q.user_id = g.user_id
        AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) < 2
  ) t;

  RETURN COALESCE(user_count, 0);
END;
$$;

-- 4) Sender: honest status + correct chunking + recorded skips.
CREATE OR REPLACE FUNCTION public.send_admin_broadcast(
  broadcast_id UUID,
  p_limit INT DEFAULT 20000,
  p_offset INT DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  broadcast_record public.admin_broadcasts%ROWTYPE;
  target_user RECORD;
  notification_count INTEGER := 0;
  scanned_count INTEGER := 0;
  skipped_freq INTEGER := 0;
  c JSONB;
  v_issues TEXT[];
  v_limit INT;
  v_offset INT;
BEGIN
  SELECT * INTO broadcast_record FROM public.admin_broadcasts WHERE id = broadcast_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Broadcast not found';
  END IF;

  v_issues := public.check_notification_limits(
    broadcast_record.title, broadcast_record.message,
    broadcast_record.action_url, broadcast_record.action_url_text
  );
  IF array_length(v_issues, 1) > 0 THEN
    UPDATE public.admin_broadcasts
    SET status = 'failed', updated_at = NOW()
    WHERE id = broadcast_id;
    RETURN jsonb_build_object('success', false, 'errors', to_jsonb(v_issues));
  END IF;

  v_limit := GREATEST(LEAST(COALESCE(p_limit, 20000), 20000), 1);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);

  c := public.normalize_broadcast_filter_criteria(broadcast_record.filter_criteria);

  IF v_offset = 0 THEN
    UPDATE public.admin_broadcasts
    SET status = 'sending',
        sent_at = NOW(),
        filter_criteria = c,
        skipped_count = 0
    WHERE id = broadcast_id;
  END IF;

  FOR target_user IN
    SELECT * FROM public.get_users_for_broadcast(c)
    ORDER BY user_id
    LIMIT v_limit OFFSET v_offset
  LOOP
    scanned_count := scanned_count + 1;

    -- Frequency guard: max 2 admin pushes per user per day. Same rule that
    -- count_target_users now applies, so confirm and send stay in sync.
    IF (
      SELECT COUNT(*) FROM public.notification_queue q
      WHERE q.user_id = target_user.user_id
        AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) >= 2 THEN
      skipped_freq := skipped_freq + 1;
      CONTINUE;
    END IF;

    INSERT INTO public.admin_broadcast_deliveries (broadcast_id, user_id, fcm_token)
    VALUES (broadcast_id, target_user.user_id, target_user.fcm_token);

    PERFORM public.queue_fcm_notification(
        target_user.user_id,
        target_user.fcm_token,
        broadcast_record.title,
        broadcast_record.message,
        jsonb_build_object(
            'type', 'admin_broadcast',
            'broadcast_id', broadcast_id,
            'action_url', broadcast_record.action_url,
            'action_url_text', broadcast_record.action_url_text
        ),
        target_user.platform
    );

    notification_count := notification_count + 1;
  END LOOP;

  -- Accumulate across chunks.
  UPDATE public.admin_broadcasts
  SET target_user_count = COALESCE(target_user_count, 0) + notification_count,
      actual_sent_count = COALESCE(actual_sent_count, 0) + notification_count,
      skipped_count = COALESCE(skipped_count, 0) + skipped_freq
  WHERE id = broadcast_id;

  -- Final chunk = fewer rows SCANNED than the chunk limit. Only then choose the
  -- terminal status. Zero deliveries (no matches, or all guard-skipped) =>
  -- 'cancelled', never a misleading 'sent'.
  IF scanned_count < v_limit THEN
    IF notification_count = 0 THEN
      UPDATE public.admin_broadcasts
      SET status = 'cancelled'
      WHERE id = broadcast_id;
    ELSE
      UPDATE public.admin_broadcasts
      SET status = 'sent'
      WHERE id = broadcast_id;
    END IF;
  END IF;

  DELETE FROM public.notification_queue
  WHERE created_at < NOW() - INTERVAL '7 days'
    AND status IN ('sent', 'failed');

  RETURN jsonb_build_object(
    'success', true,
    'sent_count', notification_count,
    'scanned_count', scanned_count,
    'skipped_frequency', skipped_freq
  );
END;
$$;

-- 5) Resend-now: the 1-arg overload was dropped by 20260916000000, so call the
--    3-arg guarded overload. Runs fully, including the frequency guard.
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

GRANT EXECUTE ON FUNCTION public.count_target_users(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.count_target_users(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.send_admin_broadcast(uuid, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_resend_broadcast_now(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resend_broadcast_now(uuid) TO service_role;

-- 6) UI strings for the new status and the skipped counter.
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminBroadcastsStatusCancelled', 'Cancelled'),
  ('es', 'adminBroadcastsStatusCancelled', 'Cancelado'),
  ('he', 'adminBroadcastsStatusCancelled', 'בוטל'),
  ('en', 'adminBroadcastsSkipped', 'Skipped'),
  ('es', 'adminBroadcastsSkipped', 'Omitidos'),
  ('he', 'adminBroadcastsSkipped', 'הושמטו')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;