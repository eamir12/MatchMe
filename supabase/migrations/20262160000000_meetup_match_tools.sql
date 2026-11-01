-- Meet-up tools independent of the location invite.
--
-- Wave/beacon and Spot me used to live inside a meet-up session, so they only
-- worked after one participant sent a location invite and the other side had
-- not ended it. Product decision: these tools belong to the match itself.
-- They work before a place is proposed, while it is pending, while a meet-up
-- is active, and after the invite is cancelled/declined/ended. Only expiry
-- (60 s wave, 120 s beacon, 2 h Spot me card) or an explicit Hide/Delete
-- stops them.
--
-- What changes:
--   1. meetup_signals.session_id and meetup_spot_cards.session_id become
--      nullable. Match-scoped rows carry only match_id.
--   2. Four match-keyed RPCs replace the session gates. The old session-keyed
--      RPCs stay untouched so installed builds keep working.
--   3. Spot photos move to m_<matchId>/<userId>/... The storage helpers accept
--      both layouts; the old session layout keeps its old rules.
--   4. Receiver notifications: AFTER INSERT triggers on meetup_signals and
--      meetup_spot_cards enqueue an FCM push for the partner and always write
--      exactly one inbox row, using the same notification_queue ->
--      user_notifications path as location sharing. No new Edge Function.
--
-- Privacy invariants are unchanged: no user coordinates are stored or sent.
-- Spot me stays selfie-only (client-enforced), photos are re-encoded without
-- EXIF, live in the private meetup-spot bucket, and expire after 2 hours. The
-- notification payload carries only identifiers and the gesture token -- no
-- photo path, outfit, note or location.
--
-- All statements are idempotent. Run after 20262159000000_meetup_coordination.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Match-scoped rows
-- ---------------------------------------------------------------------------

ALTER TABLE public.meetup_signals
  ALTER COLUMN session_id DROP NOT NULL;

ALTER TABLE public.meetup_spot_cards
  ALTER COLUMN session_id DROP NOT NULL;

CREATE INDEX IF NOT EXISTS idx_meetup_signals_match
  ON public.meetup_signals(match_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_meetup_spot_cards_match
  ON public.meetup_spot_cards(match_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- 2. Match-keyed RPCs
-- ---------------------------------------------------------------------------

-- Gestures are whitelisted server-side; an unknown token is rejected rather
-- than silently downgraded so stale clients cannot store arbitrary payloads.
CREATE OR REPLACE FUNCTION public.meetup_signal_for_match(
  p_match_id UUID,
  p_type TEXT,
  p_payload JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_signal public.meetup_signals%ROWTYPE;
  v_expires TIMESTAMPTZ;
  v_gesture TEXT;
  v_payload JSONB;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'meetup_auth_required';
  END IF;
  IF p_match_id IS NULL OR NOT public.meetup_match_participant(p_match_id) THEN
    RAISE EXCEPTION 'meetup_not_participant';
  END IF;

  IF p_payload IS NOT NULL AND char_length(p_payload::text) > 2000 THEN
    RAISE EXCEPTION 'meetup_invalid_signal';
  END IF;

  IF p_type = 'wave' THEN
    v_gesture := lower(btrim(COALESCE(p_payload->>'gesture', '')));
    IF v_gesture = '' THEN
      v_gesture := 'wave';
    END IF;
    IF v_gesture NOT IN ('wave', 'hands_up', 'jumping', 'arms_wide') THEN
      RAISE EXCEPTION 'meetup_invalid_signal';
    END IF;
    v_payload := jsonb_build_object('gesture', v_gesture);

    IF EXISTS (
      SELECT 1 FROM public.meetup_signals
      WHERE match_id = p_match_id
        AND sender_id = v_uid
        AND type = 'wave'
        AND created_at > now() - interval '30 seconds'
    ) THEN
      RAISE EXCEPTION 'meetup_wave_rate_limited';
    END IF;
    v_expires := now() + interval '60 seconds';
  ELSIF p_type = 'beacon' THEN
    IF EXISTS (
      SELECT 1 FROM public.meetup_signals
      WHERE match_id = p_match_id
        AND sender_id = v_uid
        AND type = 'beacon'
        AND created_at > now() - interval '20 seconds'
    ) THEN
      RAISE EXCEPTION 'meetup_beacon_rate_limited';
    END IF;
    DELETE FROM public.meetup_signals
    WHERE match_id = p_match_id
      AND sender_id = v_uid
      AND type = 'beacon'
      AND expires_at > now();
    v_payload := '{}'::jsonb;
    v_expires := now() + interval '120 seconds';
  ELSE
    RAISE EXCEPTION 'meetup_invalid_signal';
  END IF;

  INSERT INTO public.meetup_signals (
    session_id, match_id, sender_id, type, payload, expires_at
  ) VALUES (
    NULL, p_match_id, v_uid, p_type,
    COALESCE(v_payload, '{}'::jsonb), v_expires
  )
  RETURNING * INTO v_signal;

  RETURN to_jsonb(v_signal);
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_signal_for_match(UUID, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_signal_for_match(UUID, TEXT, JSONB) TO authenticated;

-- Taking a signal down early never depends on a session.
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

  DELETE FROM public.meetup_signals
  WHERE match_id = p_match_id
    AND sender_id = v_uid
    AND type = p_type;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_clear_signal_for_match(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_clear_signal_for_match(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.meetup_spot_share_for_match(
  p_match_id UUID,
  p_storage_path TEXT,
  p_kind TEXT,
  p_outfit JSONB DEFAULT '{}'::jsonb,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_card public.meetup_spot_cards%ROWTYPE;
  v_count INTEGER;
  v_recent BOOLEAN;
  v_note TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'meetup_auth_required';
  END IF;
  IF p_match_id IS NULL OR NOT public.meetup_match_participant(p_match_id) THEN
    RAISE EXCEPTION 'meetup_not_participant';
  END IF;

  IF p_kind IS NULL OR p_kind NOT IN ('self', 'meeting_point') THEN
    RAISE EXCEPTION 'meetup_invalid_spot_kind';
  END IF;

  IF p_outfit IS NOT NULL AND (
       jsonb_typeof(p_outfit) <> 'object'
       OR char_length(p_outfit::text) > 2000
     ) THEN
    RAISE EXCEPTION 'meetup_invalid_spot_outfit';
  END IF;

  -- A card may contain only outfit details/note and no photo at all.
  -- Compare folders exactly; LIKE would treat the "_" in "m_" as a wildcard.
  p_storage_path := COALESCE(btrim(p_storage_path), '');
  IF char_length(p_storage_path) > 512 THEN
    RAISE EXCEPTION 'meetup_invalid_spot_path';
  END IF;
  IF p_storage_path <> '' AND (
       split_part(p_storage_path, '/', 1) <> 'm_' || p_match_id::text
       OR split_part(p_storage_path, '/', 2) <> v_uid::text
       OR split_part(p_storage_path, '/', 3) = ''
     ) THEN
    RAISE EXCEPTION 'meetup_invalid_spot_path';
  END IF;

  -- The cap counts live cards only; old expired cards must not lock the tools
  -- for the lifetime of the match.
  SELECT count(*) INTO v_count
  FROM public.meetup_spot_cards
  WHERE match_id = p_match_id
    AND sender_id = v_uid
    AND deleted_at IS NULL
    AND expires_at > now();
  IF v_count >= 5 THEN
    RAISE EXCEPTION 'meetup_spot_limit';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.meetup_spot_cards
    WHERE match_id = p_match_id
      AND sender_id = v_uid
      AND created_at > now() - interval '60 seconds'
  ) INTO v_recent;
  IF v_recent THEN
    RAISE EXCEPTION 'meetup_spot_rate_limited';
  END IF;

  v_note := NULLIF(btrim(COALESCE(p_note, '')), '');
  IF v_note IS NOT NULL AND char_length(v_note) > 280 THEN
    v_note := left(v_note, 280);
  END IF;

  -- One live card per sender and match, as before.
  UPDATE public.meetup_spot_cards
  SET deleted_at = now()
  WHERE match_id = p_match_id
    AND sender_id = v_uid
    AND deleted_at IS NULL;

  INSERT INTO public.meetup_spot_cards (
    session_id, match_id, sender_id, kind, storage_path, outfit, note, expires_at
  ) VALUES (
    NULL, p_match_id, v_uid, p_kind, p_storage_path,
    COALESCE(p_outfit, '{}'::jsonb), v_note,
    now() + interval '2 hours'
  )
  RETURNING * INTO v_card;

  RETURN to_jsonb(v_card);
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_spot_share_for_match(UUID, TEXT, TEXT, JSONB, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_spot_share_for_match(UUID, TEXT, TEXT, JSONB, TEXT) TO authenticated;

-- Photo cleanup: the client asks only for rows it may safely remove, so a
-- live card's photo is never deleted out from under the other user.
CREATE OR REPLACE FUNCTION public.meetup_spot_paths_for_match(
  p_match_id UUID,
  p_only_inactive BOOLEAN DEFAULT FALSE
)
RETURNS SETOF TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT storage_path
  FROM public.meetup_spot_cards
  WHERE match_id = p_match_id
    AND session_id IS NULL
    AND public.meetup_match_participant(p_match_id)
    AND (
      NOT COALESCE(p_only_inactive, FALSE)
      OR deleted_at IS NOT NULL
      OR expires_at <= now()
    );
$$;

REVOKE ALL ON FUNCTION public.meetup_spot_paths_for_match(UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_spot_paths_for_match(UUID, BOOLEAN) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Storage: accept session folders (old builds) and m_<matchId> (new)
-- ---------------------------------------------------------------------------

-- CREATE OR REPLACE cannot rename an input parameter, and both helpers were
-- created earlier as `p_session_id`. Drop their only dependants (the three
-- storage policies below) first, then the functions, and recreate everything
-- at the end of this section.
DROP POLICY IF EXISTS "Meet-up participants upload spot photos" ON storage.objects;
DROP POLICY IF EXISTS "Meet-up participants read spot photos" ON storage.objects;
DROP POLICY IF EXISTS "Meet-up participants delete spot photos" ON storage.objects;
DROP FUNCTION IF EXISTS public.meetup_storage_can_read(TEXT);
DROP FUNCTION IF EXISTS public.meetup_storage_can_write(TEXT, TEXT);

-- Parses the match id out of an m_<uuid> folder, or NULL for any other
-- folder. A session UUID can never start with "m_", so the layouts cannot
-- collide.
CREATE OR REPLACE FUNCTION public.meetup_scope_match_id(p_scope TEXT)
RETURNS UUID
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_raw TEXT;
BEGIN
  IF p_scope IS NULL OR left(p_scope, 2) <> 'm_' THEN
    RETURN NULL;
  END IF;
  v_raw := substr(p_scope, 3);
  BEGIN
    RETURN v_raw::UUID;
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_scope_match_id(TEXT) FROM PUBLIC;
-- Called directly by the storage DELETE policy below, which runs as the
-- authenticated user. Without this grant every spot-photo delete fails closed.
GRANT EXECUTE ON FUNCTION public.meetup_scope_match_id(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.meetup_storage_can_read(p_scope TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_match_id UUID := public.meetup_scope_match_id(p_scope);
BEGIN
  IF v_match_id IS NOT NULL THEN
    RETURN public.meetup_match_participant(v_match_id);
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.meetup_sessions s
    JOIN public.matches m ON m.id = s.match_id
    WHERE s.id::text = p_scope
      AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.meetup_storage_can_write(
  p_scope TEXT,
  p_owner_id TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_match_id UUID := public.meetup_scope_match_id(p_scope);
BEGIN
  IF p_owner_id IS DISTINCT FROM auth.uid()::text THEN
    RETURN FALSE;
  END IF;

  IF v_match_id IS NOT NULL THEN
    RETURN public.meetup_match_participant(v_match_id);
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.meetup_sessions s
    JOIN public.matches m ON m.id = s.match_id
    WHERE s.id::text = p_scope
      AND s.status IN ('proposed', 'active')
      AND s.expires_at > now()
      AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
  );
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_storage_can_read(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_storage_can_write(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_storage_can_read(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_storage_can_write(TEXT, TEXT) TO authenticated;

CREATE POLICY "Meet-up participants upload spot photos" ON storage.objects
FOR INSERT TO authenticated WITH CHECK (
  bucket_id = 'meetup-spot'
  AND public.meetup_storage_can_write(
    (storage.foldername(name))[1],
    (storage.foldername(name))[2]
  )
);

CREATE POLICY "Meet-up participants read spot photos" ON storage.objects
FOR SELECT TO authenticated USING (
  bucket_id = 'meetup-spot'
  AND public.meetup_storage_can_read((storage.foldername(name))[1])
);

-- In a match folder either participant may clean up: photos are ephemeral
-- and both sides must be able to purge them after expiry, whichever device
-- is awake. Session folders keep the old owner/ended-session rule.
CREATE POLICY "Meet-up participants delete spot photos" ON storage.objects
FOR DELETE TO authenticated USING (
  bucket_id = 'meetup-spot'
  AND public.meetup_storage_can_read((storage.foldername(name))[1])
  AND (
    (storage.foldername(name))[2] = auth.uid()::text
    OR public.meetup_scope_match_id((storage.foldername(name))[1]) IS NOT NULL
    OR EXISTS (
      SELECT 1 FROM public.meetup_sessions s
      WHERE s.id::text = (storage.foldername(name))[1]
        AND s.status = 'ended'
    )
  )
);

-- ---------------------------------------------------------------------------
-- 4. Cleanup: expired match-scoped cards are purged after a grace period
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cleanup_expired_meetups()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.meetup_sessions
  SET status = 'ended',
      ended_at = now(),
      end_reason = 'expired',
      pending_landmark_id = NULL,
      pending_change_by = NULL,
      pending_change_at = NULL
  WHERE status IN ('proposed', 'active')
    AND expires_at < now();

  DELETE FROM public.meetup_landmarks l
  USING public.meetup_sessions s
  WHERE l.session_id = s.id
    AND l.round = 3
    AND s.status = 'ended'
    AND l.id IS DISTINCT FROM s.chosen_landmark_id;

  DELETE FROM public.meetup_signals WHERE expires_at < now();

  UPDATE public.meetup_spot_cards
  SET deleted_at = now()
  WHERE deleted_at IS NULL
    AND expires_at < now();

  -- Keep ended sessions for a day so both clients can purge their spot
  -- objects, then drop the rows (cascade removes landmarks/signals/cards).
  DELETE FROM public.meetup_sessions
  WHERE status = 'ended'
    AND ended_at < now() - interval '24 hours';

  -- Match-scoped cards have no session to cascade with. Keep them for a day
  -- after they close so clients can purge the private photo, then drop them.
  DELETE FROM public.meetup_spot_cards
  WHERE session_id IS NULL
    AND (deleted_at IS NOT NULL OR expires_at < now())
    AND COALESCE(deleted_at, expires_at) < now() - interval '24 hours';
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_expired_meetups() FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 5. Receiver notifications (OS + inbox)
-- ---------------------------------------------------------------------------

INSERT INTO public.translations (locale, key, value) VALUES
-- English (American)
('en', 'meetupFindEachOtherTitle',        'Find each other'),
('en', 'meetupFindEachOtherHeadline',     'Find each other in person'),
('en', 'meetupFindEachOtherBody',         'Send a gesture, show a beacon, or share a Spot me card. These work any time after you match.'),
('en', 'meetupFindEachOtherPrivacy',      'No location is requested. Only what you choose to share is sent to them.'),
('en', 'meetupFindEachOtherPlanTitle',    'Plan the meet-up'),
('en', 'meetupFindEachOtherPlanBody',     'Suggest public meeting points and confirm one together. Optional.'),
('en', 'meetupFindEachOtherPrivacyFooter', 'Signals and beacons turn off on their own. Spot me cards are private to this match.'),
('en', 'meetupSpotMeIncomingBody',        'Open to see their Spot me card.'),
('en', 'meetupToolsHint',                 'These work any time after you match — no meeting point needed.'),
('en', 'cancel',                          'Cancel'),
('en', 'meetupWavePushTitle',     '👋 {name}'),
('en', 'meetupWavePushBody',      '{name} waved at you. Tap to wave back'),
('en', 'meetupHandsUpPushBody',   '{name} raised both hands to find you'),
('en', 'meetupJumpingPushBody',   '{name} is jumping to catch your eye'),
('en', 'meetupArmsWidePushBody',  '{name} has both arms up to find you'),
('en', 'meetupBeaconPushTitle',   '📡 {name}'),
('en', 'meetupBeaconPushBody',    '{name} is broadcasting a beacon so you can find each other'),
('en', 'meetupSpotPushTitle',     '📸 {name}'),
('en', 'meetupSpotPushBody',      '{name} sent a Spot me card'),
('en', 'settingsNotificationsMeetupTools',     'Find each other'),
('en', 'settingsNotificationsMeetupToolsDesc', 'Waves, beacons, and Spot me cards from your match'),
('en', 'inboxTypeMeetupSignal',   'Gesture'),
('en', 'inboxTypeMeetupBeacon',   'Beacon'),
('en', 'inboxTypeMeetupSpot',     'Spot me'),
-- Spanish
('es', 'meetupFindEachOtherTitle',        'Encontrarse'),
('es', 'meetupFindEachOtherHeadline',     'Encuéntrense en persona'),
('es', 'meetupFindEachOtherBody',         'Envía un gesto, muestra una baliza o comparte una tarjeta de Ubícame. Funcionan en cualquier momento después de la coincidencia.'),
('es', 'meetupFindEachOtherPrivacy',      'No se solicita tu ubicación. Solo se les envía lo que decidas compartir.'),
('es', 'meetupFindEachOtherPlanTitle',    'Planear el encuentro'),
('es', 'meetupFindEachOtherPlanBody',     'Sugieran puntos de encuentro públicos y confirmen uno juntos. Es opcional.'),
('es', 'meetupFindEachOtherPrivacyFooter', 'Los gestos y las balizas se apagan solos. Las tarjetas de Ubícame son privadas para esta coincidencia.'),
('es', 'meetupSpotMeIncomingBody',        'Abre para ver su tarjeta de Ubícame.'),
('es', 'meetupToolsHint',                 'Funcionan en cualquier momento después de la coincidencia, sin necesidad de un punto de encuentro.'),
('es', 'cancel',                          'Cancelar'),
('es', 'meetupWavePushTitle',     '👋 {name}'),
('es', 'meetupWavePushBody',      '{name} te saludó con la mano. Toca para responder'),
('es', 'meetupHandsUpPushBody',   '{name} levantó ambas manos para que lo encuentres'),
('es', 'meetupJumpingPushBody',   '{name} está saltando para llamar tu atención'),
('es', 'meetupArmsWidePushBody',  '{name} tiene los brazos abiertos para que lo encuentres'),
('es', 'meetupBeaconPushTitle',   '📡 {name}'),
('es', 'meetupBeaconPushBody',    '{name} está emitiendo una baliza para que se encuentren'),
('es', 'meetupSpotPushTitle',     '📸 {name}'),
('es', 'meetupSpotPushBody',      '{name} envió una tarjeta de Ubícame'),
('es', 'settingsNotificationsMeetupTools',     'Encontrarse'),
('es', 'settingsNotificationsMeetupToolsDesc', 'Saludos, balizas y tarjetas de Ubícame de tu coincidencia'),
('es', 'inboxTypeMeetupSignal',   'Gesto'),
('es', 'inboxTypeMeetupBeacon',   'Baliza'),
('es', 'inboxTypeMeetupSpot',     'Ubícame'),
-- Hebrew
('he', 'meetupFindEachOtherTitle',        'למצוא זה את זה'),
('he', 'meetupFindEachOtherHeadline',     'למצוא זה את זה פנים אל פנים'),
('he', 'meetupFindEachOtherBody',         'אפשר לשלוח תנועה, להציג איתות או לשתף כרטיס "מצא אותי". זה עובד בכל שלב אחרי ההתאמה.'),
('he', 'meetupFindEachOtherPrivacy',      'לא נדרש מיקום. רק מה שתבחרו לשתף נשלח אליהם.'),
('he', 'meetupFindEachOtherPlanTitle',    'לתכנן את המפגש'),
('he', 'meetupFindEachOtherPlanBody',     'אפשר להציע נקודות מפגש ציבוריות ולאשר אחת יחד. זה אופציונלי.'),
('he', 'meetupFindEachOtherPrivacyFooter', 'תנועות ואיתותים נכבים מעצמם. כרטיסי "מצא אותי" פרטיים להתאמה הזו.'),
('he', 'meetupSpotMeIncomingBody',        'פתחו כדי לראות את כרטיס "מצא אותי" שלהם.'),
('he', 'meetupToolsHint',                 'זה עובד בכל שלב אחרי ההתאמה, בלי צורך בנקודת מפגש.'),
('he', 'cancel',                          'ביטול'),
('he', 'meetupWavePushTitle',     '👋 {name}'),
('he', 'meetupWavePushBody',      '{name} נופף/ה לך לשלום. הקש/י כדי לנופף בחזרה'),
('he', 'meetupHandsUpPushBody',   '{name} הרים/ה את שתי הידיים כדי שתמצא/י אותו/ה'),
('he', 'meetupJumpingPushBody',   '{name} קופץ/ת כדי לתפוס את תשומת לבך'),
('he', 'meetupArmsWidePushBody',  '{name} פורש/ת את הידיים כדי שתמצא/י אותו/ה'),
('he', 'meetupBeaconPushTitle',   '📡 {name}'),
('he', 'meetupBeaconPushBody',    '{name} משדר/ת איתות כדי שתוכלו למצוא זה את זה'),
('he', 'meetupSpotPushTitle',     '📸 {name}'),
('he', 'meetupSpotPushBody',      '{name} שלח/ה כרטיס "מצא אותי"'),
('he', 'settingsNotificationsMeetupTools',     'למצוא זה את זה'),
('he', 'settingsNotificationsMeetupToolsDesc', 'נופפים, איתותים וכרטיסי "מצא אותי" מההתאמה שלך'),
('he', 'inboxTypeMeetupSignal',   'ניפוף'),
('he', 'inboxTypeMeetupBeacon',   'איתות'),
('he', 'inboxTypeMeetupSpot',     'מצא אותי')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Shared enqueue helper: one inbox row always; FCM only when the recipient
-- allows it and has a live token. Mirrors notify_location_share_started.
CREATE OR REPLACE FUNCTION public._meetup_notify_partner(
  p_actor_id UUID,
  p_match_id UUID,
  p_type TEXT,
  p_title TEXT,
  p_body TEXT,
  p_data JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_match public.matches%ROWTYPE;
  v_partner_id UUID;
  v_prefs JSONB;
  v_token TEXT;
  v_platform TEXT;
  v_any_token BOOLEAN := FALSE;
BEGIN
  IF p_actor_id IS NULL OR p_match_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_match FROM public.matches WHERE id = p_match_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF p_actor_id = v_match.user1_id THEN
    v_partner_id := v_match.user2_id;
  ELSIF p_actor_id = v_match.user2_id THEN
    v_partner_id := v_match.user1_id;
  ELSE
    RETURN;
  END IF;
  IF v_partner_id IS NULL THEN
    RETURN;
  END IF;

  SELECT u.notification_preferences INTO v_prefs
  FROM public.users u
  WHERE u.id = v_partner_id;

  -- Inbox records every tool event, regardless of push preferences or
  -- registered devices. The dedupe trigger collapses multi-device retries.
  IF NOT public._match_extended_push_enabled(
       v_prefs, 'meetup_tools', 'enable_meetup_notifications'
     ) THEN
    INSERT INTO public.user_notifications (user_id, type, title, body, data)
    VALUES (v_partner_id, p_type, p_title, p_body, p_data);
    RETURN;
  END IF;

  FOR v_token, v_platform IN
    SELECT DISTINCT ON (NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''))
      NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') AS fcm_token,
      us.platform
    FROM public.user_session us
    WHERE us.user_id = v_partner_id
      AND us.revoked = false
      AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
    ORDER BY NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''), us.last_active_at DESC NULLS LAST
  LOOP
    v_any_token := TRUE;
    INSERT INTO public.notification_queue (
      user_id, fcm_token, title, body, data, platform
    )
    VALUES (
      v_partner_id,
      v_token,
      p_title,
      p_body,
      p_data,
      COALESCE(NULLIF(btrim(v_platform), ''), 'unknown')
    );
  END LOOP;

  IF NOT v_any_token THEN
    INSERT INTO public.user_notifications (user_id, type, title, body, data)
    VALUES (v_partner_id, p_type, p_title, p_body, p_data);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._meetup_notify_partner(UUID, UUID, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.notify_meetup_signal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_locale TEXT;
  v_name TEXT;
  v_first TEXT;
  v_someone TEXT;
  v_title TEXT;
  v_body TEXT;
  v_kind TEXT;
  v_gesture TEXT;
  v_data JSONB;
BEGIN
  IF NEW.sender_id IS NULL OR NEW.match_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Re-sending a beacon inserts a fresh row and stays live for 120 s. Alert
  -- at most once per two minutes instead of buzzing on every re-send.
  IF NEW.type = 'beacon' AND EXISTS (
    SELECT 1
    FROM public.user_notifications un
    JOIN public.matches m ON m.id = NEW.match_id
    WHERE un.user_id = CASE
        WHEN m.user1_id = NEW.sender_id THEN m.user2_id
        ELSE m.user1_id
      END
      AND un.type = 'meetup_beacon'
      AND un.data->>'match_id' = NEW.match_id::text
      AND un.data->>'sender_id' = NEW.sender_id::text
      AND un.created_at > now() - interval '2 minutes'
  ) THEN
    RETURN NEW;
  END IF;

  SELECT lower(btrim(COALESCE(u.preferred_language, 'en'))), u.name
    INTO v_locale, v_name
  FROM public.users u
  WHERE u.id IN (
    SELECT CASE
      WHEN m.user1_id = NEW.sender_id THEN m.user2_id
      ELSE m.user1_id
    END
    FROM public.matches m
    WHERE m.id = NEW.match_id
  );

  v_locale := COALESCE(v_locale, 'en');
  IF v_locale LIKE 'he%' THEN v_locale := 'he';
  ELSIF v_locale LIKE 'es%' THEN v_locale := 'es';
  ELSE v_locale := 'en';
  END IF;

  v_first := left(split_part(btrim(COALESCE(v_name, '')), ' ', 1), 20);
  v_someone := CASE
    WHEN v_locale = 'he' THEN 'מישהו'
    WHEN v_locale = 'es' THEN 'Alguien'
    ELSE 'Someone'
  END;
  v_first := COALESCE(NULLIF(v_first, ''), v_someone);

  IF NEW.type = 'beacon' THEN
    v_kind := 'meetup_beacon';
    v_title := replace(
      public._match_extended_text(v_locale, 'meetupBeaconPushTitle', '📡 {name}'),
      '{name}', v_first);
    v_body := replace(
      public._match_extended_text(v_locale, 'meetupBeaconPushBody',
        '{name} is broadcasting a beacon so you can find each other'),
      '{name}', v_first);
  ELSE
    v_kind := 'meetup_signal';
    v_gesture := lower(btrim(COALESCE(NEW.payload->>'gesture', '')));
    IF v_gesture NOT IN ('wave', 'hands_up', 'jumping', 'arms_wide') THEN
      v_gesture := 'wave';
    END IF;
    v_title := replace(
      public._match_extended_text(v_locale, 'meetupWavePushTitle', '👋 {name}'),
      '{name}', v_first);
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
      '{name}', v_first);
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

  PERFORM public._meetup_notify_partner(
    NEW.sender_id, NEW.match_id, v_kind, v_title, v_body, v_data
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- A failed alert must never block the signal itself.
  RAISE WARNING 'notify_meetup_signal failed: %', SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_meetup_signal ON public.meetup_signals;
CREATE TRIGGER trg_notify_meetup_signal
  AFTER INSERT ON public.meetup_signals
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_meetup_signal();

CREATE OR REPLACE FUNCTION public.notify_meetup_spot()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_locale TEXT;
  v_name TEXT;
  v_first TEXT;
  v_someone TEXT;
  v_title TEXT;
  v_body TEXT;
  v_data JSONB;
BEGIN
  IF NEW.sender_id IS NULL OR NEW.match_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT lower(btrim(COALESCE(u.preferred_language, 'en'))), u.name
    INTO v_locale, v_name
  FROM public.users u
  WHERE u.id IN (
    SELECT CASE
      WHEN m.user1_id = NEW.sender_id THEN m.user2_id
      ELSE m.user1_id
    END
    FROM public.matches m
    WHERE m.id = NEW.match_id
  );

  v_locale := COALESCE(v_locale, 'en');
  IF v_locale LIKE 'he%' THEN v_locale := 'he';
  ELSIF v_locale LIKE 'es%' THEN v_locale := 'es';
  ELSE v_locale := 'en';
  END IF;

  v_first := left(split_part(btrim(COALESCE(v_name, '')), ' ', 1), 20);
  v_someone := CASE
    WHEN v_locale = 'he' THEN 'מישהו'
    WHEN v_locale = 'es' THEN 'Alguien'
    ELSE 'Someone'
  END;
  v_first := COALESCE(NULLIF(v_first, ''), v_someone);

  v_title := replace(
    public._match_extended_text(v_locale, 'meetupSpotPushTitle', '📸 {name}'),
    '{name}', v_first);
  v_body := replace(
    public._match_extended_text(v_locale, 'meetupSpotPushBody',
      '{name} sent a Spot me card'),
    '{name}', v_first);

  -- No photo path, outfit, note or location in the payload.
  v_data := jsonb_build_object(
    'type', 'meetup_spot',
    'kind', 'meetup_spot',
    'matchId', NEW.match_id::text,
    'match_id', NEW.match_id::text,
    'senderId', NEW.sender_id::text,
    'sender_id', NEW.sender_id::text,
    'meetup_spot_id', NEW.id::text,
    'spot_kind', NEW.kind
  );

  PERFORM public._meetup_notify_partner(
    NEW.sender_id, NEW.match_id, 'meetup_spot', v_title, v_body, v_data
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'notify_meetup_spot failed: %', SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_meetup_spot ON public.meetup_spot_cards;
CREATE TRIGGER trg_notify_meetup_spot
  AFTER INSERT ON public.meetup_spot_cards
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_meetup_spot();

-- One inbox row per (user, tool event), mirroring the message_id index. The
-- indexes make the queue capture trigger's ON CONFLICT DO NOTHING effective
-- even when two workers drain the same event concurrently; the keys were
-- introduced by this migration, so no pre-existing duplicates can block them.
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_notifications_meetup_signal_dedupe
  ON public.user_notifications (user_id, (data->>'meetup_signal_id'))
  WHERE COALESCE(data->>'meetup_signal_id', '') <> '';

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_notifications_meetup_spot_dedupe
  ON public.user_notifications (user_id, (data->>'meetup_spot_id'))
  WHERE COALESCE(data->>'meetup_spot_id', '') <> '';

-- Multi-device queue rows collapse to one inbox row per tool event.
CREATE OR REPLACE FUNCTION public.trg_user_notifications_dedupe()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_message_id TEXT;
  v_match_id TEXT;
  v_threshold TEXT;
  v_expiry_at TEXT;
  v_signal_id TEXT;
  v_spot_id TEXT;
BEGIN
  v_message_id := COALESCE(NEW.data->>'message_id', '');
  v_match_id := COALESCE(NEW.data->>'match_id', COALESCE(NEW.data->>'matchId', ''));
  v_signal_id := COALESCE(NEW.data->>'meetup_signal_id', '');
  v_spot_id := COALESCE(NEW.data->>'meetup_spot_id', '');

  IF v_message_id <> '' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.data->>'message_id' = v_message_id
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  IF v_match_id <> '' AND NEW.type IN ('match', 'new_match') THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.type IN ('match', 'new_match')
        AND COALESCE(un.data->>'match_id', un.data->>'matchId', '') = v_match_id
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  -- Expiry warnings: cron writes the row directly and the queue capture
  -- trigger writes one row per device token. Keep the first copy. These
  -- branches must stay in sync with the partial unique indexes from
  -- 20262147000000_dedupe_expiry_inbox_notifications.sql.
  v_threshold := COALESCE(NEW.data->>'threshold_seconds', '');
  v_expiry_at := COALESCE(NEW.data->>'expiry_at', '');

  IF NEW.type = 'match_expiry' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.type = 'match_expiry'
        AND COALESCE(un.data->>'match_id', un.data->>'matchId', '') = v_match_id
        AND COALESCE(un.data->>'threshold_seconds', '') = v_threshold
        AND COALESCE(un.data->>'expiry_at', '') = v_expiry_at
    ) THEN
      RETURN NULL;
    END IF;
  ELSIF NEW.type = 'pinned_expiry' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.type = 'pinned_expiry'
        AND COALESCE(un.data->>'threshold_seconds', '') = v_threshold
        AND COALESCE(un.data->>'expiry_at', '') = v_expiry_at
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  IF v_signal_id <> '' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.data->>'meetup_signal_id' = v_signal_id
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  IF v_spot_id <> '' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.data->>'meetup_spot_id' = v_spot_id
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_notifications_dedupe ON public.user_notifications;
CREATE TRIGGER trg_user_notifications_dedupe
  BEFORE INSERT ON public.user_notifications
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_user_notifications_dedupe();

NOTIFY pgrst, 'reload schema';

COMMIT;
