-- Migration: Name-free banner title + gender backfill for match-extension notices.
--
-- Two follow-ups to 20262074000000:
--
-- 1) matchExtendedBannerTitle contained a {name} placeholder, but the only
--    renderer (match_notification_overlay.dart) passes the name as a separate
--    subtitle line (same pattern as the new-match banner: name-free
--    'newMatchTitle' + name subtitle) and never supplies {name} params — so
--    the overlay displayed a literal "{name}". The push title
--    (matchExtendedPushTitle) keeps the name: FCM cards have no subtitle, so
--    the title must carry it. Banner copy is now name-free and gender-free in
--    all three locales (הוארכה agrees with ההתאמה; the actor needs no verb
--    agreement). The gendered _male/_female/_non_binary banner rows are kept
--    in sync because the client's getString(key, gender:) resolves the
--    gendered key FIRST when a gender is known.
--
-- 2) Backfill: user_notifications rows of type 'match_extended' written before
--    the gender fix store the pre-rendered push title with the hardcoded
--    feminine Hebrew verb ("... נתנה לך יותר זמן"). Recompute each row's title
--    from the actor's current name (re-masked via mask_full_name) and gender,
--    exactly as notify_match_extended does now. Rows whose actor no longer
--    exists are left untouched. Idempotent: rows whose title already matches
--    are not rewritten.

BEGIN;

-- 1) Banner copy: name-free / gender-free, consistent with the
--    settingsNotificationsMatchExtended labels.
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'matchExtendedBannerTitle', 'Match extended!'),
  ('he', 'matchExtendedBannerTitle', 'ההתאמה הוארכה!'),
  ('es', 'matchExtendedBannerTitle', '¡Coincidencia ampliada!'),

  ('en', 'matchExtendedBannerTitle_male',        'Match extended!'),
  ('en', 'matchExtendedBannerTitle_female',      'Match extended!'),
  ('en', 'matchExtendedBannerTitle_non_binary',  'Match extended!'),

  ('he', 'matchExtendedBannerTitle_male',        'ההתאמה הוארכה!'),
  ('he', 'matchExtendedBannerTitle_female',      'ההתאמה הוארכה!'),
  ('he', 'matchExtendedBannerTitle_non_binary',  'ההתאמה הוארכה!'),

  ('es', 'matchExtendedBannerTitle_male',        '¡Coincidencia ampliada!'),
  ('es', 'matchExtendedBannerTitle_female',      '¡Coincidencia ampliada!'),
  ('es', 'matchExtendedBannerTitle_non_binary',  '¡Coincidencia ampliada!')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- 2) Backfill gendered push titles on existing inbox rows.
DO $$
DECLARE
  r RECORD;
  v_locale text;
  v_masked text;
  v_copy_gender text;
  v_title text;
  v_updated int := 0;
  v_skipped int := 0;
BEGIN
  FOR r IN
    SELECT un.id,
           un.title,
           lower(btrim(COALESCE(ru.preferred_language, 'en'))) AS locale,
           au.name AS actor_name,
           au.gender AS actor_gender
    FROM public.user_notifications un
    LEFT JOIN public.users ru ON ru.id = un.user_id
    LEFT JOIN public.users au
      ON au.id::text = COALESCE(
           NULLIF(btrim(COALESCE(un.data->>'other_user_id', '')), ''),
           NULLIF(btrim(COALESCE(un.data->>'otherUserId', '')), '')
         )
    WHERE un.type = 'match_extended'
  LOOP
    IF r.actor_name IS NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF r.locale LIKE 'he%' THEN v_locale := 'he';
    ELSIF r.locale LIKE 'es%' THEN v_locale := 'es';
    ELSE v_locale := 'en';
    END IF;

    BEGIN
      v_masked := public.mask_full_name(r.actor_name);
    EXCEPTION WHEN OTHERS THEN
      v_masked := NULL;
    END;

    IF v_masked IS NULL OR btrim(v_masked) = '' THEN
      v_masked := CASE
        WHEN v_locale = 'he' THEN 'מישהו'
        WHEN v_locale = 'es' THEN 'Alguien'
        ELSE 'Someone'
      END;
      v_copy_gender := NULL;
    ELSE
      v_copy_gender := r.actor_gender;
    END IF;

    v_title := replace(
      public._match_extended_text(
        v_locale, 'matchExtendedPushTitle', '{name} gave you more time', v_copy_gender
      ), '{name}', v_masked);

    IF v_title IS DISTINCT FROM r.title THEN
      UPDATE public.user_notifications SET title = v_title WHERE id = r.id;
      v_updated := v_updated + 1;
    END IF;
  END LOOP;

  RAISE NOTICE 'match_extended inbox backfill: % updated, % skipped (no actor)', v_updated, v_skipped;
END;
$$;

COMMIT;
