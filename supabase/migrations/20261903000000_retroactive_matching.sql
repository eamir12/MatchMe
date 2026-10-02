-- Migration: Retroactive matching (offline trail)
-- Stores places recorded while offline, matches them later, auto-deletes per user choice.
BEGIN;

-- 1) Per-user settings (opt-in + retention hours, guarded 2..72)
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS retro_matching_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS retro_retention_hours int NOT NULL DEFAULT 24;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'users_retro_retention_chk'
  ) THEN
    ALTER TABLE public.users
      ADD CONSTRAINT users_retro_retention_chk
      CHECK (retro_retention_hours BETWEEN 2 AND 72);
  END IF;
END $$;

-- 2) Offline trail table: one row per recorded place, kept only until chosen time
CREATE TABLE IF NOT EXISTS public.offline_location_history (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  recorded_at timestamptz NOT NULL,
  latitude double precision NOT NULL CHECK (latitude BETWEEN -90 AND 90),
  longitude double precision NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  accuracy_m double precision,
  uploaded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, recorded_at)
);
CREATE INDEX IF NOT EXISTS idx_offline_hist_recorded
  ON public.offline_location_history (recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_offline_hist_uploaded
  ON public.offline_location_history (uploaded_at DESC);
CREATE INDEX IF NOT EXISTS idx_offline_hist_user_recorded
  ON public.offline_location_history (user_id, recorded_at DESC);

ALTER TABLE public.offline_location_history ENABLE ROW LEVEL SECURITY;
-- No policies for anon/authenticated => denied by default.
-- Access only via SECURITY DEFINER RPCs below (service_role / authenticated grant on functions).

-- 3) Flag on matches so UI can show offline-origin without new match_type
-- (keeps cleanup/unmatch/extension functions untouched — they filter on proximity/event/co_motion)
ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS is_retroactive boolean NOT NULL DEFAULT false;

-- 4) App config defaults (admin tunable without redeploy)
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value, allowed_values) VALUES
  ('retro.distance_meters', '100', 'number', 'gps', 'Max distance between two offline places to count as being near each other (meters)', false, 10, 1000, null),
  ('retro.time_window_seconds', '180', 'duration_seconds', 'gps', 'Max time difference between two offline places to count as being near each other (seconds)', false, 30, 900, null),
  ('retro.retention_options_hours', '[2,6,12,24,72]', 'array', 'profile', 'Allowed choices for how long offline places are remembered (hours)', true, null, null, '[2,6,12,24,72]'),
  ('retro.retention_min_hours', '2', 'number', 'profile', 'Minimum hours offline places can be remembered', false, 1, 72, null),
  ('retro.retention_max_hours', '72', 'number', 'profile', 'Maximum hours offline places can be remembered', false, 2, 168, null),
  ('retro.retention_default_hours', '24', 'number', 'profile', 'Default hours offline places are remembered for new users', true, 2, 72, null),
  ('retro.max_points_per_upload', '500', 'number', 'sync', 'Maximum offline places accepted per upload call', false, 50, 2000, null)
ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value,
    config_type = EXCLUDED.config_type,
    category = EXCLUDED.category,
    description = EXCLUDED.description,
    is_user_configurable = EXCLUDED.is_user_configurable,
    min_value = EXCLUDED.min_value,
    max_value = EXCLUDED.max_value,
    allowed_values = EXCLUDED.allowed_values;

-- 5) Upload RPC: inserts caller's points, runs retro matching, returns counts
DROP FUNCTION IF EXISTS public.upload_offline_trail(jsonb);
CREATE OR REPLACE FUNCTION public.upload_offline_trail(p_points jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_enabled boolean;
  v_retention int;
  v_max_points int := 500;
  v_added int := 0;
  v_rows int := 0;
  p jsonb;
  v_lat double precision;
  v_lng double precision;
  v_acc double precision;
  v_rec timestamptz;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '28000';
  END IF;
  SELECT retro_matching_enabled, retro_retention_hours
    INTO v_enabled, v_retention FROM public.users WHERE id = v_user_id;
  IF NOT FOUND OR COALESCE(v_enabled, false) = false THEN
    RETURN jsonb_build_object('inserted', 0, 'matches', 0, 'disabled', true);
  END IF;
  SELECT NULLIF(config_value::text,'')::int INTO v_max_points
    FROM public.app_config WHERE config_key = 'retro.max_points_per_upload' LIMIT 1;
  IF v_max_points IS NULL OR v_max_points < 50 THEN v_max_points := 500; END IF;
  IF v_max_points > 2000 THEN v_max_points := 2000; END IF;

  IF p_points IS NULL OR jsonb_typeof(p_points) <> 'array' THEN
    RAISE EXCEPTION 'points_must_be_array' USING ERRCODE = '22004';
  END IF;

  FOR p IN SELECT j FROM jsonb_array_elements(p_points) AS j LIMIT v_max_points LOOP
    BEGIN
      v_lat := (p ->> 'lat')::double precision;
      v_lng := (p ->> 'lng')::double precision;
      v_rec := (p ->> 'recorded_at')::timestamptz;
    EXCEPTION WHEN OTHERS THEN CONTINUE; END;
    IF v_lat IS NULL OR v_lng IS NULL OR v_rec IS NULL THEN CONTINUE; END IF;
    IF v_lat < -90 OR v_lat > 90 OR v_lng < -180 OR v_lng > 180 THEN CONTINUE; END IF;
    -- Drop points older than the user's own chosen window (can't resurrect deleted)
    IF v_rec < now() - make_interval(hours => v_retention) THEN CONTINUE; END IF;
    -- Drop very inaccurate fixes
    BEGIN v_acc := (p ->> 'accuracy')::double precision; EXCEPTION WHEN OTHERS THEN v_acc := NULL; END;
    IF v_acc IS NOT NULL AND v_acc > 150 THEN CONTINUE; END IF;
    INSERT INTO public.offline_location_history (user_id, recorded_at, latitude, longitude, accuracy_m)
    VALUES (v_user_id, v_rec, v_lat, v_lng, v_acc)
    ON CONFLICT (user_id, recorded_at) DO NOTHING;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 1 THEN v_added := v_added + 1; END IF;
  END LOOP;

  PERFORM public.perform_retroactive_matching(v_user_id);

  RETURN jsonb_build_object('inserted', v_added, 'matches', 0, 'disabled', false);
END;
$$;
GRANT EXECUTE ON FUNCTION public.upload_offline_trail(jsonb) TO authenticated;

-- 6) Retro matcher: compares uploader's kept points vs other users' kept points
-- close in both place (<= retro.distance_meters) and time (<= retro.time_window_seconds),
-- reusing live compatibility rules (shared mode + shared interest + not already matched).
DROP FUNCTION IF EXISTS public.perform_retroactive_matching(uuid);
CREATE OR REPLACE FUNCTION public.perform_retroactive_matching(p_user_id uuid)
RETURNS TABLE (matches_created integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dist_m double precision := 100;
  v_time_s int := 180;
  v_max_occ int := 3;
  v_created int := 0;
  r RECORD;
  v_a uuid; v_b uuid;
  v_hist RECORD;
  v_next_occurrence int;
  v_center_lat double precision;
  v_center_lng double precision;
  v_zoom double precision := 14.5;
  v_dist_km double precision;
  v_my_ret int; v_other_ret int;
  v_my_enabled boolean; v_other_enabled boolean;
  my_intents TEXT[]; other_intents TEXT[];
  shared TEXT[];
  my_interests jsonb; other_interests jsonb;
  my_prefs jsonb; other_prefs jsonb;
  my_gender text; my_dob date; my_age int;
  other_gender text; other_dob date; other_age int;
  my_life jsonb; my_fam jsonb; my_rel jsonb; my_h int;
  other_life jsonb; other_fam jsonb; other_rel jsonb; other_h int;
  s text; ok boolean;
  cur_sub TEXT[]; oth_sub TEXT[];
  a_g boolean; b_g boolean; a_a boolean; b_a boolean;
  v_intent text;
BEGIN
  SELECT NULLIF(config_value::text,'')::int INTO v_dist_m FROM public.app_config WHERE config_key='retro.distance_meters' LIMIT 1;
  IF v_dist_m IS NULL OR v_dist_m <= 0 THEN v_dist_m := 100; END IF;
  IF v_dist_m > 1000 THEN v_dist_m := 1000; END IF;
  SELECT NULLIF(config_value::text,'')::int INTO v_time_s FROM public.app_config WHERE config_key='retro.time_window_seconds' LIMIT 1;
  IF v_time_s IS NULL OR v_time_s <= 0 THEN v_time_s := 180; END IF;
  IF v_time_s > 900 THEN v_time_s := 900; END IF;
  v_max_occ := public._get_max_match_occurrence();

  SELECT retro_matching_enabled, retro_retention_hours INTO v_my_enabled, v_my_ret
    FROM public.users WHERE id = p_user_id;
  IF NOT FOUND OR COALESCE(v_my_enabled,false) = false THEN
    RETURN QUERY SELECT 0; RETURN;
  END IF;
  SELECT gender, date_of_birth INTO my_gender, my_dob FROM public.users WHERE id = p_user_id;
  IF my_dob IS NOT NULL THEN my_age := EXTRACT(YEAR FROM AGE(my_dob)); END IF;
  SELECT lifestyle, family, religion, height,
         ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)),
         public.merge_interest_maps(COALESCE(personal_interests,'{}'::jsonb), COALESCE(business_interests,'{}'::jsonb)),
         intent_preferences
    INTO my_life, my_fam, my_rel, my_h, my_intents, my_interests, my_prefs
    FROM public.user_profiles WHERE user_id = p_user_id;
  IF my_intents IS NULL OR array_length(my_intents,1) IS NULL THEN
    RETURN QUERY SELECT 0; RETURN;
  END IF;

  FOR r IN
    SELECT h1.recorded_at AS t1, h1.latitude AS lat1, h1.longitude AS lng1,
           h2.user_id AS other_id, h2.recorded_at AS t2, h2.latitude AS lat2, h2.longitude AS lng2
    FROM public.offline_location_history h1
    JOIN public.offline_location_history h2
      ON h2.user_id <> p_user_id
     AND abs(extract(epoch from (h1.recorded_at - h2.recorded_at))) <= v_time_s
    WHERE h1.user_id = p_user_id
      AND h1.recorded_at >= now() - make_interval(hours => v_my_ret)
      AND h2.recorded_at >= h1.recorded_at - make_interval(secs => v_time_s)
      AND h2.recorded_at <= h1.recorded_at + make_interval(secs => v_time_s)
      AND (6371.0 * acos(LEAST(1.0, GREATEST(-1.0,
          cos(radians(h1.latitude)) * cos(radians(h2.latitude))
          * cos(radians(h2.longitude) - radians(h1.longitude))
          + sin(radians(h1.latitude)) * sin(radians(h2.latitude)))))) * 1000.0 <= v_dist_m
    LIMIT 2000
  LOOP
    -- Other user opted in?
    SELECT retro_matching_enabled, retro_retention_hours, gender, date_of_birth
      INTO v_other_enabled, v_other_ret, other_gender, other_dob
      FROM public.users WHERE id = r.other_id;
    IF COALESCE(v_other_enabled,false) = false THEN CONTINUE; END IF;
    IF r.t2 < now() - make_interval(hours => v_other_ret) THEN CONTINUE; END IF;

    -- Already matched / permanently unmatched?
    IF EXISTS (SELECT 1 FROM public.matches
                WHERE (user1_id = p_user_id AND user2_id = r.other_id)
                   OR (user1_id = r.other_id AND user2_id = p_user_id)) THEN CONTINUE; END IF;
    v_a := LEAST(p_user_id, r.other_id); v_b := GREATEST(p_user_id, r.other_id);
    SELECT expiry_count, is_permanent INTO v_hist FROM public.unmatched_pairs WHERE user1_id = v_a AND user2_id = v_b;
    IF FOUND AND COALESCE(v_hist.is_permanent,false) = true THEN CONTINUE; END IF;
    IF FOUND AND COALESCE(v_hist.expiry_count,0) >= v_max_occ THEN CONTINUE; END IF;
    v_next_occurrence := COALESCE(v_hist.expiry_count,0) + 1;
    IF v_next_occurrence > v_max_occ THEN CONTINUE; END IF;

    SELECT lifestyle, family, religion, height,
           ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)),
           public.merge_interest_maps(COALESCE(personal_interests,'{}'::jsonb), COALESCE(business_interests,'{}'::jsonb)),
           intent_preferences
      INTO other_life, other_fam, other_rel, other_h, other_intents, other_interests, other_prefs
      FROM public.user_profiles WHERE user_id = r.other_id;
    IF other_intents IS NULL OR array_length(other_intents,1) IS NULL THEN CONTINUE; END IF;
    SELECT ARRAY(SELECT i FROM unnest(my_intents) AS t(i) WHERE i = ANY(other_intents)) INTO shared;
    IF shared IS NULL OR array_length(shared,1) IS NULL THEN CONTINUE; END IF;

    v_intent := NULL;
    <<intent_loop>> FOREACH s IN ARRAY shared LOOP
      cur_sub := ARRAY(SELECT jsonb_array_elements_text(COALESCE((SELECT up.sub_intents -> s FROM public.user_profiles up WHERE up.user_id = p_user_id), '[]'::jsonb)));
      oth_sub := ARRAY(SELECT jsonb_array_elements_text(COALESCE((SELECT up.sub_intents -> s FROM public.user_profiles up WHERE up.user_id = r.other_id), '[]'::jsonb)));
      IF cur_sub IS NULL OR oth_sub IS NULL OR array_length(cur_sub,1) IS NULL OR array_length(oth_sub,1) IS NULL THEN CONTINUE intent_loop; END IF;
      IF NOT (cur_sub && oth_sub) THEN CONTINUE intent_loop; END IF;
      IF other_dob IS NOT NULL THEN other_age := EXTRACT(YEAR FROM AGE(other_dob)); ELSE other_age := NULL; END IF;
      a_g := (NOT ((other_prefs -> 'gender_preferences') ? s) OR ((other_prefs -> 'gender_preferences') -> s) ? my_gender);
      b_g := (NOT ((my_prefs -> 'gender_preferences') ? s) OR ((my_prefs -> 'gender_preferences') -> s) ? other_gender);
      IF NOT a_g OR NOT b_g THEN CONTINUE intent_loop; END IF;
      a_a := (NOT ((other_prefs -> 'age_preferences') ? s) OR my_age IS NULL OR (jsonb_array_length((other_prefs -> 'age_preferences') -> s) >= 2 AND my_age >= (((other_prefs -> 'age_preferences') -> s ->> 0)::numeric) AND my_age <= (((other_prefs -> 'age_preferences') -> s ->> 1)::numeric)));
      b_a := (NOT ((my_prefs -> 'age_preferences') ? s) OR other_age IS NULL OR (jsonb_array_length((my_prefs -> 'age_preferences') -> s) >= 2 AND other_age >= (((my_prefs -> 'age_preferences') -> s ->> 0)::numeric) AND other_age <= (((my_prefs -> 'age_preferences') -> s ->> 1)::numeric)));
      IF NOT a_a OR NOT b_a THEN CONTINUE intent_loop; END IF;
      ok := public.are_filters_compatible(my_life, my_fam, my_rel, my_h, other_life, other_fam, other_rel, other_h,
        (other_prefs -> 'lifestyle_filters'), (other_prefs -> 'family_filters'), (other_prefs -> 'religion_filters'), (other_prefs -> 'height_preferences'),
        (my_prefs -> 'lifestyle_filters'), (my_prefs -> 'family_filters'), (my_prefs -> 'religion_filters'), (my_prefs -> 'height_preferences'), s);
      IF NOT COALESCE(ok,false) THEN CONTINUE intent_loop; END IF;
      IF my_interests IS NULL OR other_interests IS NULL OR my_interests = '{}'::jsonb OR other_interests = '{}'::jsonb THEN CONTINUE intent_loop; END IF;
      IF NOT EXISTS (SELECT 1 FROM jsonb_object_keys(my_interests) AS cat
                     WHERE my_interests ? cat AND other_interests ? cat
                       AND jsonb_array_length(my_interests->cat) > 0 AND jsonb_array_length(other_interests->cat) > 0
                       AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(my_interests->cat) AS sub
                                   WHERE sub = ANY(SELECT jsonb_array_elements_text(other_interests->cat)))) THEN CONTINUE intent_loop; END IF;
      v_intent := s; EXIT intent_loop;
    END LOOP intent_loop;
    IF v_intent IS NULL THEN CONTINUE; END IF;

    -- Coarse center (~1.1km truncation) like live matching; never store exact trail in matches
    v_center_lat := ROUND(((r.lat1 + r.lat2)/2)::numeric, 2)::double precision;
    v_center_lng := ROUND(((r.lng1 + r.lng2)/2)::numeric, 2)::double precision;
    v_dist_km := (6371.0 * acos(LEAST(1.0, GREATEST(-1.0,
        cos(radians(r.lat1)) * cos(radians(r.lat2)) * cos(radians(r.lng2) - radians(r.lng1))
        + sin(radians(r.lat1)) * sin(radians(r.lat2))))))::double precision;
    IF v_dist_km < 0.3 THEN v_zoom := 16;
    ELSIF v_dist_km < 0.6 THEN v_zoom := 15.5;
    ELSIF v_dist_km < 1.0 THEN v_zoom := 15;
    ELSIF v_dist_km < 2.0 THEN v_zoom := 14.5;
    ELSIF v_dist_km < 5.0 THEN v_zoom := 13.5;
    ELSIF v_dist_km < 10.0 THEN v_zoom := 12.5;
    ELSE v_zoom := 11; END IF;

    BEGIN
      INSERT INTO public.matches (user1_id, user2_id, matched_intent, match_type, created_at, match_occurrence, map_center_lat, map_center_lng, map_zoom, is_retroactive)
      VALUES (v_a, v_b, v_intent, 'proximity', NOW(), v_next_occurrence, v_center_lat, v_center_lng, v_zoom, true);
      v_created := v_created + 1;
    EXCEPTION WHEN unique_violation THEN
      -- already matched concurrently; skip
      CONTINUE;
    END;
    -- No EXIT: keep scanning — the EXISTS check above skips pairs already
    -- matched earlier in this run, so one trail can match several people.
  END LOOP;

  RETURN QUERY SELECT v_created;
END;
$$;
GRANT EXECUTE ON FUNCTION public.perform_retroactive_matching(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_retroactive_matching(uuid) TO service_role;

-- 7) Per-user expiry: honors each user's own chosen time (shorter choice wins per side)
DROP FUNCTION IF EXISTS public.cleanup_expired_offline_trail();
CREATE OR REPLACE FUNCTION public.cleanup_expired_offline_trail()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_deleted int := 0;
BEGIN
  DELETE FROM public.offline_location_history h
  USING public.users u
  WHERE h.user_id = u.id
    AND (
      h.recorded_at < now() - make_interval(hours => GREATEST(2, LEAST(72, COALESCE(u.retro_retention_hours, 24))))
      OR h.uploaded_at < now() - make_interval(hours => GREATEST(2, LEAST(72, COALESCE(u.retro_retention_hours, 24))))
    );
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_offline_trail() TO service_role;

-- 8) Self-service delete + disable wipe
DROP FUNCTION IF EXISTS public.delete_my_offline_trail();
CREATE OR REPLACE FUNCTION public.delete_my_offline_trail()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_user_id uuid := auth.uid(); v_deleted int := 0;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '28000'; END IF;
  DELETE FROM public.offline_location_history WHERE user_id = v_user_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;
GRANT EXECUTE ON FUNCTION public.delete_my_offline_trail() TO authenticated;

-- 9) Lowering the chosen time purges immediately; turning off wipes everythingDROP FUNCTION IF EXISTS public._purge_offline_trail_on_settings() CASCADE;
CREATE OR REPLACE FUNCTION public._purge_offline_trail_on_settings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(NEW.retro_matching_enabled, false) = false THEN
    DELETE FROM public.offline_location_history WHERE user_id = NEW.id;
  ELSIF NEW.retro_retention_hours < COALESCE(OLD.retro_retention_hours, NEW.retro_retention_hours) THEN
    DELETE FROM public.offline_location_history h
    WHERE h.user_id = NEW.id
      AND (h.recorded_at < now() - make_interval(hours => GREATEST(2, LEAST(72, NEW.retro_retention_hours)))
        OR h.uploaded_at < now() - make_interval(hours => GREATEST(2, LEAST(72, NEW.retro_retention_hours))));
  END IF;
  -- Clamp out-of-range writes from older clients
  IF NEW.retro_retention_hours < 2 THEN NEW.retro_retention_hours := 2; END IF;
  IF NEW.retro_retention_hours > 72 THEN NEW.retro_retention_hours := 72; END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_purge_offline_trail_on_settings ON public.users;
CREATE TRIGGER trg_purge_offline_trail_on_settings
  BEFORE UPDATE OF retro_matching_enabled, retro_retention_hours ON public.users
  FOR EACH ROW EXECUTE FUNCTION public._purge_offline_trail_on_settings();

-- 10) UI strings (en + es + he). Plain language, no jargon.
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'settingsRetroMatching', 'Find people you were near without internet'),
  ('en', 'settingsRetroMatchingDesc', 'If you lose internet — for example in a tunnel, on the subway, or in a crowded place — MatchMe can still remember where you were, and look for people you were near once you are back online.'),
  ('en', 'settingsRetroMatchingUpdated', 'Preference updated'),
  ('en', 'settingsRetroMatchingUpdateFailed', 'Failed to update preference'),
  ('en', 'settingsRetroRetention', 'How long should we remember where you were?'),
  ('en', 'settingsRetroRetentionDesc', 'Shorter time keeps less about you, but you may miss people who come back later. Longer time finds more people, but remembers where you were for longer.'),
  ('en', 'settingsRetroRetentionExample', 'Example: Choose 1 day, and we can still find someone from yesterday who only came back today. After that time, this information is deleted automatically.'),
  ('en', 'settingsRetroRetentionUpdated', 'Time updated'),
  ('en', 'settingsRetroDeleteNow', 'Delete my saved places now'),
  ('en', 'settingsRetroDeleteNowDone', 'Saved places deleted'),
  ('en', 'settingsRetroPending', 'Saved places on this device: {count}'),
  ('en', 'settingsRetroHours', '{count} hours'),
  ('en', 'settingsRetroOneDay', '1 day'),
  ('en', 'settingsRetroDays', '{count} days'),
  ('en', 'retroBanner', 'You were near each other without internet. This match was found after you were back online.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'settingsRetroMatching', 'Encuentra personas que estuvieron cerca de ti sin internet'),
  ('es', 'settingsRetroMatchingDesc', 'Si te quedas sin internet — por ejemplo en un túnel, en el metro o en un lugar con mucha gente — MatchMe puede recordar dónde estuviste y buscar a las personas que estuvieron cerca de ti cuando vuelvas a estar en línea.'),
  ('es', 'settingsRetroMatchingUpdated', 'Preferencia actualizada'),
  ('es', 'settingsRetroMatchingUpdateFailed', 'No se pudo actualizar la preferencia'),
  ('es', 'settingsRetroRetention', '¿Cuánto tiempo debemos recordar dónde estuviste?'),
  ('es', 'settingsRetroRetentionDesc', 'Con un tiempo corto guardamos menos información sobre ti, pero puedes perderte a personas que vuelvan más tarde. Con un tiempo largo encuentras a más personas, pero recordamos dónde estuviste durante más tiempo.'),
  ('es', 'settingsRetroRetentionExample', 'Ejemplo: elige 1 día y todavía podremos encontrar a alguien de ayer que volvió hoy. Después de ese tiempo, esta información se elimina automáticamente.'),
  ('es', 'settingsRetroRetentionUpdated', 'Tiempo actualizado'),
  ('es', 'settingsRetroDeleteNow', 'Borrar mis lugares guardados ahora'),
  ('es', 'settingsRetroDeleteNowDone', 'Lugares guardados eliminados'),
  ('es', 'settingsRetroPending', 'Lugares guardados en este dispositivo: {count}'),
  ('es', 'settingsRetroHours', '{count} horas'),
  ('es', 'settingsRetroOneDay', '1 día'),
  ('es', 'settingsRetroDays', '{count} días'),
  ('es', 'retroBanner', 'Estuviste cerca de esta persona sin internet. Esta coincidencia se encontró cuando volviste a estar en línea.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'settingsRetroMatching', 'מצא אנשים שהיו קרובים אליך בלי אינטרנט'),
  ('he', 'settingsRetroMatchingDesc', 'אם נגמר לך האינטרנט — למשל במנהרה, ברכבת התחתית או במקום עמוס — MatchMe יכול לזכור איפה היית, ולחפש אנשים שהיו קרובים אליך אחרי שתחזור להיות מחובר.'),
  ('he', 'settingsRetroMatchingUpdated', 'ההעדפה עודכנה'),
  ('he', 'settingsRetroMatchingUpdateFailed', 'לא הצלחנו לעדכן את ההעדפה'),
  ('he', 'settingsRetroRetention', 'כמה זמן לזכור איפה היית?'),
  ('he', 'settingsRetroRetentionDesc', 'זמן קצר שומר פחות מידע עליך, אבל אפשר לפספס אנשים שיחזרו מאוחר יותר. זמן ארוך מוצא יותר אנשים, אבל זוכר איפה היית למשך זמן ארוך יותר.'),
  ('he', 'settingsRetroRetentionExample', 'לדוגמה: בחר יום אחד, ונוכל למצוא מישהו מאתמול שחזר רק היום. אחרי הזמן הזה המידע נמחק אוטומטית.'),
  ('he', 'settingsRetroRetentionUpdated', 'הזמן עודכן'),
  ('he', 'settingsRetroDeleteNow', 'מחק עכשיו את המקומות השמורים שלי'),
  ('he', 'settingsRetroDeleteNowDone', 'המקומות השמורים נמחקו'),
  ('he', 'settingsRetroPending', 'מקומות שמורים במכשיר הזה: {count}'),
  ('he', 'settingsRetroHours', '{count} שעות'),
  ('he', 'settingsRetroOneDay', 'יום אחד'),
  ('he', 'settingsRetroDays', '{count} ימים'),
  ('he', 'retroBanner', 'הייתם קרובים זה לזה בלי אינטרנט. ההתאמה הזו נמצאה אחרי שחזרת להיות מחובר.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
