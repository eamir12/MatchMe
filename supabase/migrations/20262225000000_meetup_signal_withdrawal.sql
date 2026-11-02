-- Stop a signal's banners and notification cards as soon as its sender takes
-- it down. Replacements still use the superseded path in
-- 20262224000000_meetup_signal_newest.sql so already-sent events remain visible.

BEGIN;

CREATE OR REPLACE FUNCTION public.meetup_clear_signal_for_match(
  p_match_id UUID,
  p_type TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_partner_id UUID;
  v_notification_type TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'meetup_auth_required';
  END IF;
  IF p_match_id IS NULL OR NOT public.meetup_match_participant(p_match_id) THEN
    RAISE EXCEPTION 'meetup_not_participant';
  END IF;
  IF p_type IS NULL OR p_type NOT IN ('wave', 'beacon') THEN
    RAISE EXCEPTION 'meetup_invalid_signal';
  END IF;

  SELECT CASE
    WHEN user1_id = v_uid THEN user2_id
    ELSE user1_id
  END
  INTO v_partner_id
  FROM public.matches
  WHERE id = p_match_id;

  v_notification_type := CASE p_type
    WHEN 'wave' THEN 'meetup_signal'
    ELSE 'meetup_beacon'
  END;

  -- Prevent a queued push from arriving after the sender has withdrawn it.
  UPDATE public.notification_queue
  SET status = 'skipped',
      failure_reason = 'meetup_signal_withdrawn',
      lease_until = NULL,
      updated_at = now()
  WHERE user_id = v_partner_id
    AND status = 'pending'
    AND data->>'type' = v_notification_type
    AND COALESCE(data->>'match_id', data->>'matchId') = p_match_id::text
    AND COALESCE(data->>'sender_id', data->>'senderId') = v_uid::text;

  -- The inbox update is replicated to the recipient. Their app uses it to
  -- remove the in-app alert and cancel the matching OS/browser card.
  UPDATE public.user_notifications
  SET read_at = COALESCE(read_at, now()),
      data = (data - 'superseded') || jsonb_build_object('withdrawn', true)
  WHERE user_id = v_partner_id
    AND type = v_notification_type
    AND deleted_at IS NULL
    AND COALESCE(data->>'match_id', data->>'matchId') = p_match_id::text
    AND COALESCE(data->>'sender_id', data->>'senderId') = v_uid::text
    AND data->>'withdrawn' IS DISTINCT FROM 'true';

  DELETE FROM public.meetup_signals
  WHERE match_id = p_match_id
    AND sender_id = v_uid
    AND type = p_type;

  RETURN TRUE;
END;
$$;

COMMIT;
