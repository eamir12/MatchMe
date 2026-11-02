-- Meet-up signals: the newest one wins, everywhere.
--
-- Two surfaces still answered "which signal did the other person send?" with a
-- rule of their own, and disagreed with the alert bar, the chat banner and the
-- hub:
--
--   1. `meetup_activity_by_match` ranked an incoming beacon (4) above an
--      incoming wave (6) by tool type. A wave sent a minute after the beacon was
--      switched on therefore lost the match-card line to the older tool. The
--      same call returns no gesture, so the card reads "Alex waves / You waved"
--      for hands-up, jumping and arms-wide alike — the only surface in the app
--      that cannot say what was actually sent.
--   2. `notify_meetup_signal` appended an inbox row per send and nothing settled
--      the row the send replaced. The signal *row* is deleted and re-inserted on
--      a resend (20262217000000), so `trg_user_notifications_dedupe` — which
--      collapses by `meetup_signal_id` — sees a fresh identity every time and
--      keeps the row. The replaced alert therefore outlives the thing it
--      announced and holds the bell and the unread Matches badge until someone
--      clears it. Production on 2026-11-01: 56 signal/beacon alerts in 14 days,
--      55 already read — the client's own auto-clear sweeps them when the app
--      runs — and 1 left holding a badge for a signal row that no longer exists.
--      That is the wrong shape of guarantee: the server knows the signal was
--      replaced at the moment it happens, and a client should not have to
--      discover it later.
--
-- The fixes:
--
--   * Both signal kinds share one rank per direction (4 for theirs, 9 for
--     yours) and are ordered by `created_at DESC` inside it, so the newest
--     signal wins. No other tool's rank moves: the numbers stay unique across
--     kinds, so the new tie-break can only ever pick between two signal rows of
--     the same direction — exactly the case that was wrong.
--     Consequence to be aware of: an incoming wave now ranks above their Spot me
--     card, where it used to rank below it. That asymmetry only ever existed
--     because wave and beacon were two numbers; a beacon already outranked the
--     card. Signaling someone is the more urgent of the two, so the wave moves
--     up rather than the beacon moving down.
--   * `top_gesture` is returned for a winning wave so the card can name the
--     gesture; a beacon carries none and returns NULL.
--   * A new signal settles the recipient's unread signal rows from the same
--     sender for the same match and stamps them `superseded`. The client reads
--     that stamp to keep the notification-shade card of a superseded signal:
--     the badge and the inbox are what should forget, the shade keeps both
--     cards, because a wave and a beacon are two things that really happened.
--   * The alerts that were already stranded before this change are settled the
--     same way, once, in section 3.
--
-- `notify_meetup_signal` is replaced, not dropped, so its object identity, the
-- INSERT trigger on `meetup_signals` and its grants (including service_role) all
-- survive. The aggregate is dropped and recreated, so its grants are re-applied
-- in the same transaction; the result matches the production ACL exactly
-- (postgres + authenticated, no PUBLIC).
--
-- Idempotent. Both functions are recreated from their live definitions with only
-- the changes above. The DROP + CREATE pair on the aggregate needs the shared
-- transaction because `RETURNS TABLE` gains a column (42P13 otherwise).

BEGIN;

-- ---------------------------------------------------------------------------
-- 1 · The aggregate: newest signal wins, and it says which gesture
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.meetup_activity_by_match();

CREATE OR REPLACE FUNCTION public.meetup_activity_by_match()
RETURNS TABLE (
  match_id UUID,
  top_kind TEXT,
  top_own BOOLEAN,
  top_label TEXT,
  top_gesture TEXT,
  tool_count INTEGER,
  next_expiry TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH me AS (
    SELECT auth.uid() AS uid
  ),
  my_matches AS (
    SELECT m.id AS match_id
    FROM public.matches m
    CROSS JOIN me
    WHERE me.uid IS NOT NULL
      AND (m.user1_id = me.uid OR m.user2_id = me.uid)
  ),
  candidates AS (
    -- Meeting point: pending change, pending proposal, or active meet-up.
    SELECT
      s.match_id,
      CASE
        WHEN s.status = 'active' AND s.pending_landmark_id IS NOT NULL
          THEN 'place_change'
        WHEN s.status = 'proposed' THEN 'proposal'
        ELSE 'active'
      END AS kind,
      CASE
        WHEN s.status = 'active' AND s.pending_landmark_id IS NOT NULL
          THEN s.pending_change_by = me.uid
        WHEN s.status = 'proposed' THEN s.proposed_by = me.uid
        ELSE FALSE
      END AS own,
      CASE
        WHEN s.status = 'active' AND s.pending_landmark_id IS NULL
          THEN chosen.label
        ELSE NULL
      END AS top_label,
      NULL::TEXT AS top_gesture,
      CASE
        WHEN s.status = 'active' AND s.pending_landmark_id IS NOT NULL THEN
          CASE WHEN s.pending_change_by = me.uid THEN 12 ELSE 1 END
        WHEN s.status = 'proposed' THEN
          CASE WHEN s.proposed_by = me.uid THEN 11 ELSE 2 END
        ELSE 7
      END AS priority,
      NULL::TIMESTAMPTZ AS event_time,
      'meeting' AS tool,
      s.expires_at AS expires_at
    FROM public.meetup_sessions s
    JOIN my_matches mm ON mm.match_id = s.match_id
    LEFT JOIN public.meetup_landmarks chosen
      ON chosen.id = s.chosen_landmark_id
    CROSS JOIN me
    WHERE s.status IN ('proposed', 'active')
      AND s.expires_at > now()

    UNION ALL

    -- Signals are match-scoped and live without a session. Wave and beacon hold
    -- the same rank per direction; the newest of them wins by created_at.
    SELECT
      sig.match_id,
      sig.type,
      sig.sender_id = me.uid,
      NULL::TEXT AS top_label,
      CASE
        WHEN sig.type = 'wave'
          THEN NULLIF(lower(btrim(COALESCE(sig.payload->>'gesture', ''))), '')
        ELSE NULL
      END AS top_gesture,
      CASE WHEN sig.sender_id = me.uid THEN 9 ELSE 4 END AS priority,
      sig.created_at AS event_time,
      CASE WHEN sig.type = 'beacon' THEN 'beacon' ELSE 'signal' END AS tool,
      sig.expires_at
    FROM public.meetup_signals sig
    JOIN my_matches mm ON mm.match_id = sig.match_id
    CROSS JOIN me
    WHERE sig.expires_at > now()

    UNION ALL

    -- Spot me cards. Hidden or deleted cards are not in use for either side.
    SELECT
      c.match_id,
      'spot' AS kind,
      c.sender_id = me.uid AS own,
      NULL::TEXT AS top_label,
      NULL::TEXT AS top_gesture,
      CASE WHEN c.sender_id <> me.uid THEN 5 ELSE 10 END AS priority,
      NULL::TIMESTAMPTZ AS event_time,
      'spot' AS tool,
      c.expires_at
    FROM public.meetup_spot_cards c
    JOIN my_matches mm ON mm.match_id = c.match_id
    CROSS JOIN me
    WHERE c.deleted_at IS NULL
      AND c.hidden_at IS NULL
      AND c.expires_at > now()

    UNION ALL

    -- Live location: row existence is the sharing state.
    SELECT
      m2.id AS match_id,
      'live' AS kind,
      lss.sharer_id = me.uid AS own,
      NULL::TEXT AS top_label,
      NULL::TEXT AS top_gesture,
      CASE WHEN lss.sharer_id <> me.uid THEN 3 ELSE 8 END AS priority,
      NULL::TIMESTAMPTZ AS event_time,
      'live' AS tool,
      lss.expires_at
    FROM public.location_share_signals lss
    JOIN public.matches m2 ON m2.id::text = lss.match_id
    JOIN my_matches mm ON mm.match_id = m2.id
    CROSS JOIN me
    WHERE lss.expires_at IS NULL OR lss.expires_at > now()
  ),
  ranked AS (
    SELECT
      candidates.match_id,
      candidates.kind,
      candidates.own,
      candidates.top_label,
      candidates.top_gesture,
      ROW_NUMBER() OVER (
        PARTITION BY candidates.match_id
        ORDER BY
          candidates.priority,
          candidates.own,
          candidates.event_time DESC NULLS LAST
      ) AS position
    FROM candidates
  ),
  totals AS (
    SELECT
      candidates.match_id,
      COUNT(DISTINCT candidates.tool)::INTEGER AS tool_count,
      MIN(candidates.expires_at) AS next_expiry
    FROM candidates
    GROUP BY candidates.match_id
  )
  SELECT
    ranked.match_id,
    ranked.kind,
    ranked.own,
    ranked.top_label,
    ranked.top_gesture,
    totals.tool_count,
    totals.next_expiry
  FROM ranked
  JOIN totals ON totals.match_id = ranked.match_id
  WHERE ranked.position = 1;
$$;

REVOKE ALL ON FUNCTION public.meetup_activity_by_match() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_activity_by_match() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2 · A new signal settles the inbox rows the send replaced
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.notify_meetup_signal()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_locale TEXT;
  v_name TEXT;
  v_display TEXT;
  v_someone TEXT;
  v_title TEXT;
  v_body TEXT;
  v_kind TEXT;
  v_gesture TEXT;
  v_data JSONB;
  v_partner_id UUID;
BEGIN
  IF NEW.sender_id IS NULL OR NEW.match_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT CASE
      WHEN m.user1_id = NEW.sender_id THEN m.user2_id
      WHEN m.user2_id = NEW.sender_id THEN m.user1_id
    END
    INTO v_partner_id
  FROM public.matches m
  WHERE m.id = NEW.match_id;

  -- Re-sending a beacon inserts a fresh row and stays live for 120 s. Alert
  -- at most once per two minutes instead of buzzing on every re-send. A
  -- pushed partner is recorded in notification_queue (one row per device), an
  -- inbox-only partner in user_notifications, so both count as "already
  -- alerted".
  IF NEW.type = 'beacon' AND v_partner_id IS NOT NULL AND (
    EXISTS (
      SELECT 1
      FROM public.user_notifications un
      WHERE un.user_id = v_partner_id
        AND un.type = 'meetup_beacon'
        AND un.data->>'match_id' = NEW.match_id::text
        AND un.data->>'sender_id' = NEW.sender_id::text
        AND un.created_at > now() - interval '2 minutes'
    )
    OR EXISTS (
      SELECT 1
      FROM public.notification_queue q
      WHERE q.user_id = v_partner_id
        AND q.data->>'type' = 'meetup_beacon'
        AND q.data->>'match_id' = NEW.match_id::text
        AND q.data->>'sender_id' = NEW.sender_id::text
        AND q.created_at > now() - interval '2 minutes'
    )
  ) THEN
    RETURN NEW;
  END IF;

  -- Locale belongs to the receiver; the name belongs to the actor.
  SELECT lower(btrim(COALESCE(u.preferred_language, 'en')))
    INTO v_locale
  FROM public.users u
  WHERE u.id = v_partner_id;

  SELECT u.name INTO v_name
  FROM public.users u
  WHERE u.id = NEW.sender_id;

  v_locale := COALESCE(v_locale, 'en');
  IF v_locale LIKE 'he%' THEN v_locale := 'he';
  ELSIF v_locale LIKE 'es%' THEN v_locale := 'es';
  ELSE v_locale := 'en';
  END IF;

  v_someone := CASE
    WHEN v_locale = 'he' THEN 'מישהו'
    WHEN v_locale = 'es' THEN 'Alguien'
    ELSE 'Someone'
  END;
  -- mask_full_name returns NULL for a name that cannot be shown as
  -- "First L." (single-word); 'Unknown User' covers the older definition.
  v_display := COALESCE(
    NULLIF(public.mask_full_name(v_name), 'Unknown User'),
    v_someone
  );

  IF NEW.type = 'beacon' THEN
    v_kind := 'meetup_beacon';
    v_title := replace(
      public._match_extended_text(v_locale, 'meetupBeaconPushTitle', '📡 {name}'),
      '{name}', v_display);
    v_body := replace(
      public._match_extended_text(v_locale, 'meetupBeaconPushBody',
        '{name} is broadcasting a beacon so you can find each other'),
      '{name}', v_display);
  ELSE
    v_kind := 'meetup_signal';
    v_gesture := lower(btrim(COALESCE(NEW.payload->>'gesture', '')));
    IF v_gesture NOT IN ('wave', 'hands_up', 'jumping', 'arms_wide') THEN
      v_gesture := 'wave';
    END IF;
    v_title := replace(
      public._match_extended_text(v_locale, 'meetupWavePushTitle', '👋 {name}'),
      '{name}', v_display);
    v_body := replace(
      public._match_extended_text(
        v_locale,
        CASE v_gesture
          WHEN 'hands_up' THEN 'meetupHandsUpPushBody'
          WHEN 'jumping' THEN 'meetupJumpingPushBody'
          WHEN 'arms_wide' THEN 'meetupArmsWidePushBody'
          ELSE 'meetupWavePushBody'
        END,
        '{name} waved at you. Tap to wave back'
      ),
      '{name}', v_display);
  END IF;

  v_data := jsonb_build_object(
    'type', v_kind,
    'kind', v_kind,
    'matchId', NEW.match_id::text,
    'match_id', NEW.match_id::text,
    'senderId', NEW.sender_id::text,
    'sender_id', NEW.sender_id::text,
    'meetup_signal_id', NEW.id::text,
    'gesture', v_gesture
  );

  -- This send replaces the sender's previous signal, so the notifications it
  -- announced are settled: read_at drops them out of the bell and the unread
  -- Matches badge, and `superseded` tells the client not to cancel the
  -- notification-shade card that is already out there. Direction-scoped like
  -- the beacon throttle above — the other person's unread signals are separate
  -- events and stay open.
  UPDATE public.user_notifications
  SET read_at = now(),
      data = data || jsonb_build_object('superseded', true)
  WHERE user_id = v_partner_id
    AND type IN ('meetup_signal', 'meetup_beacon')
    AND read_at IS NULL
    AND deleted_at IS NULL
    AND data->>'match_id' = NEW.match_id::text
    AND data->>'sender_id' = NEW.sender_id::text;

  PERFORM public._meetup_notify_partner(
    NEW.sender_id, NEW.match_id, v_kind, v_title, v_body, v_data
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- A failed alert must never block the signal itself.
  RAISE WARNING 'notify_meetup_signal failed: %', SQLERRM;
  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3 · One-time settle of the alerts left behind before this migration
-- ---------------------------------------------------------------------------

-- A signal alert whose signal row is gone can no longer be acted on: the hub it
-- opens has no live tool in it. Those rows stop holding the bell here. They stay
-- in the inbox list (the list filters on deleted_at only), so nothing the person
-- has not seen is lost — only the unread count drops. Measured on production
-- 2026-11-01: one such row, for one user, from 2026-10-29. Rows whose signal is
-- still live are untouched, and going forward the trigger above settles the
-- replaced ones as they happen.
UPDATE public.user_notifications n
SET read_at = now(),
    data = n.data || jsonb_build_object('superseded', true)
WHERE n.read_at IS NULL
  AND n.deleted_at IS NULL
  AND n.type IN ('meetup_signal', 'meetup_beacon')
  AND NOT EXISTS (
    SELECT 1
    FROM public.meetup_signals s
    WHERE s.id::text = n.data->>'meetup_signal_id'
  );

-- ---------------------------------------------------------------------------
-- UI copy for the match-card banner (en/es/he)
-- ---------------------------------------------------------------------------

INSERT INTO public.translations (locale, key, value) VALUES
('en','meetupActivityYourGesture','You sent {gesture}'),
('es','meetupActivityYourGesture','Enviaste {gesture}'),
('he','meetupActivityYourGesture','שלחתם {gesture}')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
