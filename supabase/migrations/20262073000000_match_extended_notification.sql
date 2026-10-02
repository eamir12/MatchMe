-- Migration: Notify the other participant when someone extends a match's chat window.
--
-- Purpose:
--   Extending a match is the cheapest possible signal of interest in the product
--   (zero words, no rejection risk), but until now it was invisible to the peer:
--   extend_match_chat_window only wrote per-user columns on `matches`. The green
--   "Extended by <name>" badge only renders if the peer happens to open the app
--   and scroll to that row before the window runs out.
--
--   This migration enqueues a push for the peer at the moment the extension
--   happens, mirroring the birthday-automation and profile-edit-review pattern
--   (insert into notification_queue; the cron-jobs edge function drains it).
--
-- Design notes:
--   - One notification per user per match, guaranteed by the existing
--     `already_extended` guard in extend_match_chat_window (one extension per
--     participant), so a match can generate at most 2 of these.
--   - The actor never notifies themselves; only the peer is enqueued.
--   - Gated on the peer's own notification_preferences, so the send respects
--     pause / global_methods / matrix / legacy flag, exactly like new_match.
--   - Copy is resolved from the `translations` table for the peer's
--     preferred_language, with an English literal fallback in this migration so
--     a missing translation can never block or blank the notification.
--   - Titles/bodies are truncated by the existing trg_truncate_notification_queue
--     trigger, and are kept short deliberately (users scan push text, not read it).
--   - The actor's name is masked with public.mask_full_name, consistent with
--     get_user_recent_matches, so we never put a full name in a push payload.

BEGIN;

-- 1) Copy for the push + in-app banner, plus the notification-settings row.
--    en / es / he are the app's three supported locales (AppLanguage in
--    lib/providers/locale_provider.dart). Do not add rows for other languages:
--    an untranslated row is worse than the English fallback.
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'matchExtendedPushTitle',   '{name} gave you more time'),
  ('en', 'matchExtendedPushBody',    'Say hi before this match runs out.'),
  ('en', 'matchExtendedBannerTitle', '{name} gave you more time'),
  ('en', 'matchExtendedBannerBody',  'Say hi before this match runs out.'),
  ('en', 'settingsNotificationsMatchExtended',
        'Match Extended'),
  ('en', 'settingsNotificationsMatchExtendedDesc',
        'Get notified when someone gives you more time to say hi'),

  ('he', 'matchExtendedPushTitle',   '{name} נתנה לך יותר זמן'),
  ('he', 'matchExtendedPushBody',    'אמרו שלום לפני שההתאמה נעלמת.'),
  ('he', 'matchExtendedBannerTitle', '{name} נתנה לך יותר זמן'),
  ('he', 'matchExtendedBannerBody',  'אמרו שלום לפני שההתאמה נעלמת.'),
  ('he', 'settingsNotificationsMatchExtended',
        'הארכת התאמה'),
  ('he', 'settingsNotificationsMatchExtendedDesc',
        'קבלו התראה כשמישהו נותן לכם יותר זמן לכתוב'),

  ('es', 'matchExtendedPushTitle',   '{name} te dio más tiempo'),
  ('es', 'matchExtendedPushBody',    'Saluda antes de que esta coincidencia caduque.'),
  ('es', 'matchExtendedBannerTitle', '{name} te dio más tiempo'),
  ('es', 'matchExtendedBannerBody',  'Saluda antes de que esta coincidencia caduque.'),
  ('es', 'settingsNotificationsMatchExtended',
        'Coincidencia ampliada'),
  ('es', 'settingsNotificationsMatchExtendedDesc',
        'Recibe un aviso cuando alguien te da más tiempo para saludar')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- 2) Kill switch so this can be disabled without a redeploy.
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value, allowed_values) VALUES
  ('match_extended.notify_peer', 'true', 'boolean', 'notifications', 'Notify the other participant when a match chat window is extended', false, null, null, null)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  updated_at = now();

-- 3) Helper: resolve localized copy from `translations`, English before the literal.
CREATE OR REPLACE FUNCTION public._match_extended_text(
  p_locale text,
  p_key text,
  p_fallback text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_locale text := lower(btrim(COALESCE(p_locale, 'en')));
  v_value text;
BEGIN
  IF v_locale LIKE 'he%' THEN v_locale := 'he';
  ELSIF v_locale LIKE 'es%' THEN v_locale := 'es';
  ELSE v_locale := 'en';
  END IF;

  SELECT t.value INTO v_value
  FROM public.translations t
  WHERE t.locale = v_locale AND t.key = p_key
  LIMIT 1;

  IF v_value IS NULL OR btrim(v_value) = '' THEN
    SELECT t.value INTO v_value
    FROM public.translations t
    WHERE t.locale = 'en' AND t.key = p_key
    LIMIT 1;
  END IF;

  IF v_value IS NULL OR btrim(v_value) = '' THEN
    RETURN p_fallback;
  END IF;
  RETURN btrim(v_value);
END;
$$;

-- 4) Helper: is push enabled for this recipient?
--    Mirrors isPushEnabledForPrefs() in supabase/functions/push-message/index.ts:
--    pause window -> global_methods.push -> matrix.<key>.push -> legacy flag.
CREATE OR REPLACE FUNCTION public._match_extended_push_enabled(p_prefs jsonb, p_type text, p_legacy_key text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  p jsonb := COALESCE(p_prefs, '{}'::jsonb);
  v_until text;
  v_num numeric;
  v_node jsonb;
BEGIN
  IF jsonb_typeof(p) <> 'object' THEN RETURN true; END IF;

  -- Paused?
  IF p ? 'paused_indefinitely' THEN
    IF COALESCE((p->>'paused_indefinitely')::boolean, false) THEN RETURN false; END IF;
  END IF;
  IF p ? 'paused_until_epoch_ms_utc' THEN
    v_until := NULLIF(btrim(COALESCE(p->>'paused_until_epoch_ms_utc', '')), '');
    IF v_until IS NOT NULL THEN
      BEGIN
        v_num := v_until::numeric;
        IF v_num > (EXTRACT(EPOCH FROM now()) * 1000) THEN RETURN false; END IF;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;
  END IF;

  -- Global push off?
  v_node := p->'global_methods'->'push';
  IF v_node IS NOT NULL AND jsonb_typeof(v_node) = 'boolean' AND v_node = 'false' THEN
    RETURN false;
  END IF;

  -- Per-type push off?
  v_node := p->'matrix'->p_type->'push';
  IF v_node IS NOT NULL AND jsonb_typeof(v_node) = 'boolean' THEN
    RETURN v_node;
  END IF;

  -- Legacy boolean flag.
  IF p ? p_legacy_key THEN
    RETURN COALESCE((p->>p_legacy_key)::boolean, true);
  END IF;

  RETURN true;
END;
$$;

-- 5) Enqueue the peer notification for an extension.
--    SECURITY DEFINER so it can read the peer's sessions + prefs and write to
--    notification_queue, which no client role may do. Respects the
--    match_extended.notify_peer kill switch.
CREATE OR REPLACE FUNCTION public.notify_match_extended(
  p_actor_id uuid,
  p_match_id uuid,
  p_expires_at timestamptz,
  p_extension_seconds int
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_match public.matches%ROWTYPE;
  v_peer_id uuid;
  v_prefs jsonb;
  v_locale text;
  v_name text;
  v_title text;
  v_body text;
  v_enqueued int := 0;
  v_token text;
  v_platform text;
  v_enabled text;
BEGIN
  IF p_actor_id IS NULL OR p_match_id IS NULL THEN RETURN 0; END IF;

  SELECT NULLIF(config_value::text,'')::text INTO v_enabled
  FROM public.app_config WHERE config_key = 'match_extended.notify_peer' LIMIT 1;
  IF lower(COALESCE(v_enabled, 'true')) <> 'true' THEN RETURN 0; END IF;

  SELECT * INTO v_match FROM public.matches WHERE id = p_match_id;
  IF NOT FOUND THEN RETURN 0; END IF;

  IF p_actor_id = v_match.user1_id THEN
    v_peer_id := v_match.user2_id;
  ELSIF p_actor_id = v_match.user2_id THEN
    v_peer_id := v_match.user1_id;
  ELSE
    RETURN 0;
  END IF;
  IF v_peer_id IS NULL THEN RETURN 0; END IF;

  SELECT u.notification_preferences, u.preferred_language
    INTO v_prefs, v_locale
  FROM public.users u
  WHERE u.id = v_peer_id;

  IF NOT public._match_extended_push_enabled(
       v_prefs, 'match_extended', 'enable_match_extended_notifications'
     ) THEN
    RETURN 0;
  END IF;

  -- Masked name, consistent with get_user_recent_matches.
  BEGIN
    v_name := public.mask_full_name((SELECT u.name FROM public.users u WHERE u.id = p_actor_id));
  EXCEPTION WHEN OTHERS THEN
    v_name := NULL;
  END;
  IF v_name IS NULL OR btrim(v_name) = '' THEN
    v_name := CASE
      WHEN v_locale LIKE 'he%' THEN 'מישהו'
      WHEN v_locale LIKE 'es%' THEN 'Alguien'
      ELSE 'Someone'
    END;
  END IF;

  v_title := replace(
    public._match_extended_text(
      v_locale, 'matchExtendedPushTitle', '{name} gave you more time'
    ), '{name}', v_name);
  v_body := public._match_extended_text(
    v_locale, 'matchExtendedPushBody', 'Say hi before this match runs out.'
  );

  FOR v_token, v_platform IN
    SELECT DISTINCT ON (NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''))
      NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') AS fcm_token,
      us.platform
    FROM public.user_session us
    WHERE us.user_id = v_peer_id
      AND us.revoked = false
      AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
    ORDER BY NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''), us.last_active_at DESC NULLS LAST
  LOOP
    INSERT INTO public.notification_queue (
      user_id, fcm_token, title, body, data, platform
    )
    VALUES (
      v_peer_id,
      v_token,
      v_title,
      v_body,
      jsonb_build_object(
        'type', 'match_extended',
        'kind', 'match_extended',
        'matchId', p_match_id::text,
        'match_id', p_match_id::text,
        'otherUserId', p_actor_id::text,
        'other_user_id', p_actor_id::text,
        'extension_seconds', COALESCE(p_extension_seconds, 0),
        'expires_at', to_char(COALESCE(p_expires_at, now()), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      ),
      COALESCE(NULLIF(btrim(v_platform), ''), 'unknown')
    );
    v_enqueued := v_enqueued + 1;
  END LOOP;

  RETURN v_enqueued;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_match_extended(uuid, uuid, timestamptz, int) TO service_role;

-- 6) Extend RPC: enqueue the peer notification after a successful extension.
DROP FUNCTION IF EXISTS public.extend_match_chat_window(uuid);
CREATE OR REPLACE FUNCTION public.extend_match_chat_window(p_match_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_match public.matches%ROWTYPE;
  v_has_chat boolean;
  v_already_extended boolean;
  v_is_user1 boolean;
  v_extension_seconds int;
  v_window_cfg int;
  v_eff_window int;
  v_expires_at timestamptz;
  v_new_expires_at timestamptz;
  v_count int;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '28000';
  END IF;

  IF p_match_id IS NULL THEN
    RAISE EXCEPTION 'match_id_required' USING ERRCODE = '22004';
  END IF;

  SELECT * INTO v_match FROM public.matches WHERE id = p_match_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'match_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF v_user_id <> v_match.user1_id AND v_user_id <> v_match.user2_id THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_match.match_type NOT IN ('proximity','event','co_motion') THEN
    RAISE EXCEPTION 'match_type_not_allowed' USING ERRCODE = '42501';
  END IF;

  -- If a chat message already exists, the match no longer expires
  SELECT EXISTS (SELECT 1 FROM public.chat_messages cm WHERE cm.match_id = p_match_id LIMIT 1) INTO v_has_chat;
  IF v_has_chat THEN
    RAISE EXCEPTION 'chat_already_started' USING ERRCODE = 'P0001';
  END IF;

  -- Check if user already extended (per-user column, row is locked FOR UPDATE)
  v_is_user1 := (v_user_id = v_match.user1_id);
  v_already_extended := CASE
    WHEN v_is_user1 THEN COALESCE(v_match.chat_start_user1_extension_seconds, 0) > 0
    ELSE COALESCE(v_match.chat_start_user2_extension_seconds, 0) > 0
  END;
  IF v_already_extended THEN
    RAISE EXCEPTION 'already_extended' USING ERRCODE = 'P0001';
  END IF;

  -- Fetch extension amount from app_config
  SELECT NULLIF(config_value::text,'')::int INTO v_extension_seconds FROM public.app_config WHERE config_key = 'matches.chat_start_extension_seconds' LIMIT 1;
  IF v_extension_seconds IS NULL OR v_extension_seconds <= 0 THEN
    -- fallback to window size
    SELECT NULLIF(config_value::text,'')::int INTO v_extension_seconds FROM public.app_config WHERE config_key = 'matches.chat_start_window_seconds' LIMIT 1;
    IF v_extension_seconds IS NULL OR v_extension_seconds <= 0 THEN v_extension_seconds := 86400; END IF;
  END IF;

  -- Check expiry: compute current expires_at
  SELECT NULLIF(config_value::text,'')::int INTO v_window_cfg FROM public.app_config WHERE config_key = 'matches.chat_start_window_seconds' LIMIT 1;
  IF v_window_cfg IS NULL OR v_window_cfg <= 0 THEN v_window_cfg := 86400; END IF;
  v_eff_window := COALESCE(v_match.chat_start_window_seconds, v_window_cfg);
  v_expires_at := v_match.created_at + make_interval(secs => v_eff_window + COALESCE(v_match.chat_start_extension_seconds,0));
  IF now() >= v_expires_at THEN
    RAISE EXCEPTION 'match_expired' USING ERRCODE = 'P0001';
  END IF;

  -- Optional cap: max 2 extensions (one per participant) or up to 10 total as per constraint
  v_count := COALESCE(v_match.chat_start_extension_count, 0);
  IF v_count >= 10 THEN
    RAISE EXCEPTION 'max_extensions_reached' USING ERRCODE = 'P0001';
  END IF;

  -- Record the extension per-user (amount + when) and update totals
  UPDATE public.matches
  SET chat_start_user1_extension_seconds = CASE WHEN v_user_id = user1_id THEN v_extension_seconds ELSE COALESCE(chat_start_user1_extension_seconds, 0) END,
      chat_start_user1_extended_at = CASE WHEN v_user_id = user1_id THEN now() ELSE chat_start_user1_extended_at END,
      chat_start_user2_extension_seconds = CASE WHEN v_user_id = user2_id THEN v_extension_seconds ELSE COALESCE(chat_start_user2_extension_seconds, 0) END,
      chat_start_user2_extended_at = CASE WHEN v_user_id = user2_id THEN now() ELSE chat_start_user2_extended_at END,
      chat_start_extension_seconds = COALESCE(chat_start_extension_seconds,0) + v_extension_seconds,
      chat_start_extension_count = COALESCE(chat_start_extension_count,0) + 1
  WHERE id = p_match_id
  RETURNING * INTO v_match;

  v_new_expires_at := v_match.created_at + make_interval(secs => COALESCE(v_match.chat_start_window_seconds, v_window_cfg) + COALESCE(v_match.chat_start_extension_seconds,0));

  -- Tell the other participant. Wrapped so a notification failure can never
  -- roll back an extension the user legitimately earned.
  BEGIN
    PERFORM public.notify_match_extended(
      v_user_id, p_match_id, v_new_expires_at, v_extension_seconds
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_match_extended failed for match %: %', p_match_id, SQLERRM;
  END;

  RETURN jsonb_build_object(
    'match_id', v_match.id,
    'extension_seconds', v_extension_seconds,
    'total_extension_seconds', v_match.chat_start_extension_seconds,
    'extension_count', v_match.chat_start_extension_count,
    'chat_start_window_seconds', COALESCE(v_match.chat_start_window_seconds, v_window_cfg),
    'expires_at', v_new_expires_at,
    'created_at', v_match.created_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.extend_match_chat_window(uuid) TO authenticated;

COMMIT;
