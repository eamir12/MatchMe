-- Migration: one display-name format everywhere — "John S.".
--
-- public.mask_full_name is the server's only formatter for another person's
-- name. It now refuses to produce a name that the app never shows:
--   * an empty name or a single-word name returns NULL — the caller
--     substitutes its localized "Someone" copy instead of rendering a bare
--     first name;
--   * a repeated name ("John John") is masked ("John J."), never returned
--     bare the way the old last = first branch did;
--   * the first word is title-cased (initcap also handles hyphens and
--     apostrophes), matching the client formatter;
--   * the result keeps the bidi mark of its own script so the trailing
--     period stays glued to the initial in an RTL paragraph.
--
-- get_masked_sender_name returns '' instead of NULL (the chat push path and
-- the Android background service treat empty as "use the localized
-- Someone"). notify_location_share_started is recreated on the masked name,
-- plus a backfill of the location-share inbox rows that were rendered with
-- the sharer's first name only.
--
-- The user's own name is deliberately not affected: their profile, the home
-- greeting and the {first_name} birthday/profile-reminder broadcasts keep
-- showing it in full.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) The one server-side masker.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mask_full_name(full_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  parts TEXT[];
  first_part TEXT;
  last_part TEXT;
  masked TEXT;
  rtl BOOLEAN;
BEGIN
  -- Drop the bidi controls a previous call may have added, so re-masking an
  -- already-masked name ("John S.") returns it unchanged.
  full_name := translate(
    full_name,
    chr(8206) || chr(8207) || chr(8234) || chr(8235) || chr(8236) ||
      chr(8237) || chr(8238) || chr(8294) || chr(8295) || chr(8296) || chr(8297),
    ''
  );

  IF full_name IS NULL OR btrim(full_name) = '' THEN
    RETURN NULL;
  END IF;

  parts := regexp_split_to_array(btrim(full_name), '\s+');
  IF parts IS NULL OR array_length(parts, 1) < 2 THEN
    -- A single word cannot produce "First L." and must never be shown bare.
    RETURN NULL;
  END IF;

  first_part := initcap(parts[1]);
  last_part := parts[array_length(parts, 1)];
  IF first_part IS NULL OR btrim(first_part) = ''
     OR last_part IS NULL OR btrim(last_part) = '' THEN
    RETURN NULL;
  END IF;

  -- last_part may repeat first_part ("John John"): still mask it.
  masked := first_part || ' ' || upper(left(last_part, 1)) || '.';

  -- The script of the name decides the mark: a Latin name gets the
  -- left-to-right mark, a Hebrew/Arabic name the right-to-left one.
  -- The class is built from chr() so it does not depend on the regex
  -- flavour: Hebrew (U+0590-U+05FF) and Arabic (U+0600-U+06FF).
  rtl := (first_part ~
    ('[' || chr(1424) || '-' || chr(1535) || chr(1536) || '-' || chr(1799) || ']'));

  IF rtl THEN
    RETURN chr(8207) || masked || chr(8207);
  END IF;
  RETURN chr(8206) || masked || chr(8206);
END;
$$;

GRANT EXECUTE ON FUNCTION public.mask_full_name(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mask_full_name(TEXT) TO anon;

-- ---------------------------------------------------------------------------
-- 2) Chat push sender name: '' instead of NULL for an unusable name.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_masked_sender_name(p_sender_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    full_name text;
BEGIN
    IF p_sender_id IS NULL THEN
        RETURN '';
    END IF;

    SELECT u.name INTO full_name FROM users u WHERE u.id = p_sender_id;
    RETURN COALESCE(public.mask_full_name(full_name), '');
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_masked_sender_name(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_masked_sender_name(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_masked_sender_name(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Location share push: masked sharer name, localized Someone fallback.
--    Body is otherwise the 20261001020000 version unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_location_share_started()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_match public.matches%ROWTYPE;
  v_partner_id uuid;
  v_prefs jsonb;
  v_locale text;
  v_sharer_name text;
  v_display text;
  v_someone text;
  v_title text;
  v_body text;
  v_data jsonb;
  v_token text;
  v_platform text;
  v_any_token boolean;
BEGIN
  IF NEW.sharer_id IS NULL OR NEW.match_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_match FROM public.matches WHERE id = NEW.match_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  IF NEW.sharer_id = v_match.user1_id THEN
    v_partner_id := v_match.user2_id;
  ELSIF NEW.sharer_id = v_match.user2_id THEN
    v_partner_id := v_match.user1_id;
  ELSE
    RETURN NEW;
  END IF;
  IF v_partner_id IS NULL THEN RETURN NEW; END IF;

  -- Dedupe guard: identical share session (same match + expiry) already
  -- recorded for this recipient (e.g. multi-device retry) → skip.
  IF EXISTS (
    SELECT 1 FROM public.user_notifications un
    WHERE un.user_id = v_partner_id
      AND un.type = 'location_share'
      AND un.data->>'match_id' = NEW.match_id::text
      AND COALESCE(un.data->>'expires_at', '') =
          COALESCE(to_char(NEW.expires_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '')
  ) THEN
    RETURN NEW;
  END IF;

  SELECT u.notification_preferences, lower(btrim(COALESCE(u.preferred_language, 'en')))
    INTO v_prefs, v_locale
  FROM public.users u
  WHERE u.id = v_partner_id;

  v_locale := COALESCE(v_locale, 'en');
  IF v_locale LIKE 'he%' THEN v_locale := 'he';
  ELSIF v_locale LIKE 'es%' THEN v_locale := 'es';
  ELSE v_locale := 'en';
  END IF;

  BEGIN
    v_sharer_name := (SELECT u.name FROM public.users u WHERE u.id = NEW.sharer_id);
  EXCEPTION WHEN OTHERS THEN
    v_sharer_name := NULL;
  END;

  v_someone := CASE
    WHEN v_locale = 'he' THEN 'מישהו'
    WHEN v_locale = 'es' THEN 'Alguien'
    ELSE 'Someone'
  END;

  v_display := COALESCE(public.mask_full_name(v_sharer_name), v_someone);
  IF char_length(v_display) > 40 THEN
    v_display := left(v_display, 40);
  END IF;

  v_title := replace(
    public._match_extended_text(v_locale, 'locationSharePushTitle', '📍 {name}'),
    '{name}', v_display);
  v_body := replace(
    public._match_extended_text(v_locale, 'locationSharePushBody', '{name} is sharing their live location with you'),
    '{name}', v_display);

  v_data := jsonb_build_object(
    'type', 'location_share',
    'kind', 'location_share',
    'matchId', NEW.match_id::text,
    'match_id', NEW.match_id::text,
    'sharerId', NEW.sharer_id::text,
    'sharer_id', NEW.sharer_id::text,
    'otherUserId', v_partner_id::text
  );
  IF NEW.expires_at IS NOT NULL THEN
    v_data := v_data || jsonb_build_object('expires_at', to_char(NEW.expires_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  END IF;

  -- Inbox records every share alert, regardless of push preferences or
  -- registered devices.
  IF NOT public._match_extended_push_enabled(
       v_prefs, 'location_sharing', 'enable_location_share_notifications'
     ) THEN
    INSERT INTO public.user_notifications (user_id, type, title, body, data)
    VALUES (v_partner_id, 'location_share', v_title, v_body, v_data);
    RETURN NEW;
  END IF;

  v_any_token := false;
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
    v_any_token := true;
    INSERT INTO public.notification_queue (
      user_id, fcm_token, title, body, data, platform
    )
    VALUES (
      v_partner_id,
      v_token,
      v_title,
      v_body,
      v_data,
      COALESCE(NULLIF(btrim(v_platform), ''), 'unknown')
    );
  END LOOP;

  -- No registered device: no queue row (hence no capture-trigger row), so
  -- write the inbox record directly.
  IF NOT v_any_token THEN
    INSERT INTO public.user_notifications (user_id, type, title, body, data)
    VALUES (v_partner_id, 'location_share', v_title, v_body, v_data);
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- A failed alert must never block the share itself.
  RAISE WARNING 'notify_location_share_started failed: %', SQLERRM;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4) One-off repair: location-share inbox rows rendered with the sharer's
--    first name only. Re-rendered from the sharer's current name.
-- ---------------------------------------------------------------------------
WITH share_rows AS (
  SELECT un.id,
         lower(btrim(COALESCE(ru.preferred_language, 'en'))) AS raw_locale,
         s.name AS sharer_name
  FROM public.user_notifications un
  JOIN public.users ru ON ru.id = un.user_id
  LEFT JOIN public.users s ON s.id::text = un.data->>'sharer_id'
  WHERE un.type = 'location_share'
    AND COALESCE(un.data->>'sharer_id', '') <> ''
    AND un.data->>'sharer_id' <> un.user_id::text
),
prepared AS (
  SELECT r.id,
         CASE
           WHEN r.raw_locale LIKE 'he%' THEN 'he'
           WHEN r.raw_locale LIKE 'es%' THEN 'es'
           ELSE 'en'
         END AS locale,
         COALESCE(
           NULLIF(public.mask_full_name(r.sharer_name), 'Unknown User'),
           CASE
             WHEN r.raw_locale LIKE 'he%' THEN 'מישהו'
             WHEN r.raw_locale LIKE 'es%' THEN 'Alguien'
             ELSE 'Someone'
           END
         ) AS display_name
  FROM share_rows r
)
UPDATE public.user_notifications un
SET title = replace(
      public._match_extended_text(p.locale, 'locationSharePushTitle', '📍 {name}'),
      '{name}', p.display_name),
    body = replace(
      public._match_extended_text(p.locale, 'locationSharePushBody', '{name} is sharing their live location with you'),
      '{name}', p.display_name)
FROM prepared p
WHERE un.id = p.id;

COMMIT;
