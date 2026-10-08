-- Migration: Gender-aware copy for the match-extension notification.
--
-- Problem: matchExtendedPushTitle / matchExtendedBannerTitle were seeded in
-- 20262073000000 with the verb hardcoded in the FEMININE Hebrew form
-- ("{name} נתנה לך יותר זמן"), and neither notify_match_extended nor the
-- inbox capture resolved the actor's gender. A male actor (e.g. אביהו)
-- therefore produced "אביהו ה. נתנה לך יותר זמן".
--
-- Fix, following the existing gendered-variant pattern
-- (invisibleDueTo_male/_female/_non_binary in 20260107, and the client's
-- getString(key, gender:) suffix lookup in lib/providers/locale_provider.dart):
--
--   1) Seed Hebrew _male/_female/_non_binary variants for the push + banner
--      titles, and flip the base Hebrew rows to the masculine form — Hebrew's
--      grammatical default when the gender is unknown (and the form that
--      agrees with the generic fallback name מישהו). en/es verbs are
--      ungendered, so no variants are needed there: a variant-miss falls
--      through to the base key, which reads identically.
--   2) Extend _match_extended_text with an optional actor-gender parameter
--      (existing 3-arg callers — the location-share push — keep working).
--   3) Re-create notify_match_extended (latest definition:
--      20261001010000) to fetch the actor's users.gender and request the
--      gendered variant for both the notification_queue push and the
--      user_notifications inbox row. When the name is missing and we fall
--      back to "מישהו", the gender is deliberately dropped so the copy stays
--      masculine to match the fallback pronoun.
--
-- The client's in-app overlay banner (match_notification_overlay.dart)
-- already passes the other user's gender to getString, so seeding the DB
-- variants in (1) fixes it with no app change.

BEGIN;

-- 1) Copy: masculine base + Hebrew gendered variants.
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'matchExtendedPushTitle',   '{name} נתן לך יותר זמן'),
  ('he', 'matchExtendedBannerTitle', '{name} נתן לך יותר זמן'),

  ('he', 'matchExtendedPushTitle_male',        '{name} נתן לך יותר זמן'),
  ('he', 'matchExtendedPushTitle_female',      '{name} נתנה לך יותר זמן'),
  ('he', 'matchExtendedPushTitle_non_binary',  '{name} נתן/ה לך יותר זמן'),

  ('he', 'matchExtendedBannerTitle_male',        '{name} נתן לך יותר זמן'),
  ('he', 'matchExtendedBannerTitle_female',      '{name} נתנה לך יותר זמן'),
  ('he', 'matchExtendedBannerTitle_non_binary',  '{name} נתן/ה לך יותר זמן')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- 2) Gender-aware copy resolver.
--    Variant order: '<key>_<gender>' in the recipient's locale -> '<key>' in
--    the recipient's locale -> '<key>' in English -> literal fallback.
--    Accepts the raw users.gender value ('gender_male' / 'male' / ...);
--    unknown or empty gender skips the variant lookup entirely.
CREATE OR REPLACE FUNCTION public._match_extended_text(
  p_locale text,
  p_key text,
  p_fallback text,
  p_gender text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_locale text := lower(btrim(COALESCE(p_locale, 'en')));
  v_gender text;
  v_variant text;
  v_value text;
BEGIN
  IF v_locale LIKE 'he%' THEN v_locale := 'he';
  ELSIF v_locale LIKE 'es%' THEN v_locale := 'es';
  ELSE v_locale := 'en';
  END IF;

  IF p_gender IS NOT NULL AND btrim(p_gender) <> '' THEN
    v_gender := lower(btrim(p_gender));
    IF left(v_gender, 7) = 'gender_' THEN
      v_gender := substring(v_gender from 8);
    END IF;
    v_gender := replace(v_gender, '-', '_');
    IF v_gender = 'nonbinary' THEN v_gender := 'non_binary'; END IF;
    IF v_gender IN ('male', 'female', 'non_binary') THEN
      v_variant := p_key || '_' || v_gender;
    END IF;
  END IF;

  IF v_variant IS NOT NULL THEN
    SELECT t.value INTO v_value
    FROM public.translations t
    WHERE t.locale = v_locale AND t.key = v_variant
    LIMIT 1;
  END IF;

  IF v_value IS NULL OR btrim(v_value) = '' THEN
    SELECT t.value INTO v_value
    FROM public.translations t
    WHERE t.locale = v_locale AND t.key = p_key
    LIMIT 1;
  END IF;

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

-- 3) notify_match_extended: pass the actor's gender to the copy resolver.
--    Body identical to the 20261001010000 definition except for the actor
--    lookup and the v_title call.
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
  v_actor_raw_name text;
  v_actor_gender text;
  v_copy_gender text;
  v_title text;
  v_body text;
  v_data jsonb;
  v_enqueued int := 0;
  v_token text;
  v_platform text;
  v_enabled text;
  v_any_token boolean;
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

  v_locale := lower(btrim(COALESCE(v_locale, 'en')));
  IF v_locale LIKE 'he%' THEN v_locale := 'he';
  ELSIF v_locale LIKE 'es%' THEN v_locale := 'es';
  ELSE v_locale := 'en';
  END IF;

  -- Masked name + gender of the actor, consistent with get_user_recent_matches.
  BEGIN
    SELECT u.name, u.gender
      INTO v_actor_raw_name, v_actor_gender
    FROM public.users u
    WHERE u.id = p_actor_id;
  EXCEPTION WHEN OTHERS THEN
    v_actor_raw_name := NULL;
    v_actor_gender := NULL;
  END;

  BEGIN
    v_name := public.mask_full_name(v_actor_raw_name);
  EXCEPTION WHEN OTHERS THEN
    v_name := NULL;
  END;

  IF v_name IS NULL OR btrim(v_name) = '' THEN
    v_name := CASE
      WHEN v_locale LIKE 'he%' THEN 'מישהו'
      WHEN v_locale LIKE 'es%' THEN 'Alguien'
      ELSE 'Someone'
    END;
    -- מישהו/Alguien/Someone pair with the masculine (base) verb; don't gender
    -- the copy around a generic fallback name.
    v_copy_gender := NULL;
  ELSE
    v_copy_gender := v_actor_gender;
  END IF;

  v_title := replace(
    public._match_extended_text(
      v_locale, 'matchExtendedPushTitle', '{name} gave you more time', v_copy_gender
    ), '{name}', v_name);
  v_body := public._match_extended_text(
    v_locale, 'matchExtendedPushBody', 'Say hi before this match runs out.'
  );

  v_data := jsonb_build_object(
    'type', 'match_extended',
    'kind', 'match_extended',
    'matchId', p_match_id::text,
    'match_id', p_match_id::text,
    'otherUserId', p_actor_id::text,
    'other_user_id', p_actor_id::text,
    'extension_seconds', COALESCE(p_extension_seconds, 0),
    'expires_at', to_char(COALESCE(p_expires_at, now()), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );

  -- Inbox records every extension notice, regardless of push preferences or
  -- registered devices.
  IF NOT public._match_extended_push_enabled(
       v_prefs, 'match_extended', 'enable_match_extended_notifications'
     ) THEN
    INSERT INTO public.user_notifications (user_id, type, title, body, data)
    VALUES (v_peer_id, 'match_extended', v_title, v_body, v_data);
    RETURN 1;
  END IF;

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
      v_data,
      COALESCE(NULLIF(btrim(v_platform), ''), 'unknown')
    );
    v_enqueued := v_enqueued + 1;
  END LOOP;

  -- No registered device: no queue row (hence no capture-trigger row), so
  -- write the inbox record directly.
  IF v_enqueued = 0 THEN
    INSERT INTO public.user_notifications (user_id, type, title, body, data)
    VALUES (v_peer_id, 'match_extended', v_title, v_body, v_data);
    RETURN 1;
  END IF;

  RETURN v_enqueued;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_match_extended(uuid, uuid, timestamptz, int) TO service_role;

COMMIT;
