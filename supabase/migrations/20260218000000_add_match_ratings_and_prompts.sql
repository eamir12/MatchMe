-- Migration: Add match rating system (ratings + prompts) + rating-related app_config + translations (en/es/he)

BEGIN;

-- =========================
-- 1) Tables
-- =========================

CREATE TABLE IF NOT EXISTS public.match_rating_prompts (
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  met_answer boolean,
  met_confirmed boolean NOT NULL DEFAULT false,
  met_answered_at timestamptz,
  next_prompt_at timestamptz,
  rating_submitted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT match_rating_prompts_pkey PRIMARY KEY (match_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_match_rating_prompts_user_next_prompt
  ON public.match_rating_prompts (user_id, next_prompt_at)
  WHERE next_prompt_at IS NOT NULL;

CREATE OR REPLACE FUNCTION public.update_match_rating_prompts_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_match_rating_prompts_updated_at ON public.match_rating_prompts;
CREATE TRIGGER trigger_match_rating_prompts_updated_at
BEFORE UPDATE ON public.match_rating_prompts
FOR EACH ROW
EXECUTE FUNCTION public.update_match_rating_prompts_updated_at();

CREATE TABLE IF NOT EXISTS public.match_ratings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  rater_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  ratee_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  q1 smallint NOT NULL CHECK (q1 BETWEEN 1 AND 5),
  q2 smallint NOT NULL CHECK (q2 BETWEEN 1 AND 5),
  q3 smallint NOT NULL CHECK (q3 BETWEEN 1 AND 5),
  q4 smallint NOT NULL CHECK (q4 BETWEEN 1 AND 5),
  q5 smallint NOT NULL CHECK (q5 BETWEEN 1 AND 5),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT match_ratings_one_per_rater_per_match UNIQUE (match_id, rater_id)
);

CREATE INDEX IF NOT EXISTS idx_match_ratings_ratee_created_at
  ON public.match_ratings (ratee_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_match_ratings_match_id
  ON public.match_ratings (match_id);

-- =========================
-- 2) RLS
-- =========================

ALTER TABLE public.match_rating_prompts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.match_ratings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "match_rating_prompts_select_own" ON public.match_rating_prompts;
DROP POLICY IF EXISTS "match_rating_prompts_upsert_own" ON public.match_rating_prompts;
DROP POLICY IF EXISTS "match_rating_prompts_update_own" ON public.match_rating_prompts;
DROP POLICY IF EXISTS "match_ratings_select_own" ON public.match_ratings;
DROP POLICY IF EXISTS "match_ratings_insert_own" ON public.match_ratings;

CREATE POLICY "match_rating_prompts_select_own"
  ON public.match_rating_prompts
  FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
  );

CREATE POLICY "match_rating_prompts_upsert_own"
  ON public.match_rating_prompts
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.matches m
      WHERE m.id = match_id
        AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
    )
  );

CREATE POLICY "match_rating_prompts_update_own"
  ON public.match_rating_prompts
  FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "match_ratings_select_own"
  ON public.match_ratings
  FOR SELECT
  TO authenticated
  USING (
    rater_id = auth.uid() OR ratee_id = auth.uid()
  );

CREATE POLICY "match_ratings_insert_own"
  ON public.match_ratings
  FOR INSERT
  TO authenticated
  WITH CHECK (
    rater_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.matches m
      WHERE m.id = match_id
        AND (
          (m.user1_id = auth.uid() AND ratee_id = m.user2_id)
          OR (m.user2_id = auth.uid() AND ratee_id = m.user1_id)
        )
    )
  );

REVOKE UPDATE ON public.match_ratings FROM authenticated;
REVOKE DELETE ON public.match_ratings FROM authenticated;

-- =========================
-- 3) RPCs
-- =========================

DROP FUNCTION IF EXISTS public.get_due_match_rating_prompts(uuid, integer, integer);
CREATE OR REPLACE FUNCTION public.get_due_match_rating_prompts(
  p_user_id uuid,
  p_initial_delay_seconds integer,
  p_limit integer DEFAULT 1
)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  match_created_at timestamptz,
  other_user_met_confirmed boolean,
  self_met_confirmed boolean,
  next_prompt_at timestamptz
) AS $$
WITH user_matches AS (
  SELECT m.id AS match_id,
         m.created_at AS created_at,
         CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END AS other_user_id
  FROM public.matches m
  WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
),
due_missing_rows AS (
  SELECT um.match_id, p_user_id AS user_id,
         (um.created_at + make_interval(secs => p_initial_delay_seconds)) AS next_prompt_at
  FROM user_matches um
  LEFT JOIN public.match_rating_prompts mrp
    ON mrp.match_id = um.match_id AND mrp.user_id = p_user_id
  WHERE mrp.match_id IS NULL
    AND (um.created_at + make_interval(secs => p_initial_delay_seconds)) <= now()
),
inserted AS (
  INSERT INTO public.match_rating_prompts (match_id, user_id, next_prompt_at)
  SELECT match_id, user_id, next_prompt_at
  FROM due_missing_rows
  ON CONFLICT (match_id, user_id) DO NOTHING
  RETURNING match_id
),
due_prompts AS (
  SELECT mrp.match_id,
         mrp.user_id,
         mrp.next_prompt_at,
         mrp.met_confirmed AS self_met_confirmed
  FROM public.match_rating_prompts mrp
  WHERE mrp.user_id = p_user_id
    AND mrp.rating_submitted_at IS NULL
    AND mrp.next_prompt_at IS NOT NULL
    AND mrp.next_prompt_at <= now()
)
SELECT dp.match_id,
       um.other_user_id,
       public.mask_full_name(u.name) AS other_name,
       um.created_at AS match_created_at,
       COALESCE(otherp.met_confirmed, false) AS other_user_met_confirmed,
       dp.self_met_confirmed,
       dp.next_prompt_at
FROM due_prompts dp
JOIN user_matches um ON um.match_id = dp.match_id
LEFT JOIN public.users u ON u.id = um.other_user_id
LEFT JOIN public.match_rating_prompts otherp
  ON otherp.match_id = dp.match_id AND otherp.user_id = um.other_user_id
ORDER BY dp.next_prompt_at ASC
LIMIT p_limit;
$$ LANGUAGE sql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.get_due_match_rating_prompts(uuid, integer, integer) TO authenticated;

DROP FUNCTION IF EXISTS public.set_match_met_answer(uuid, boolean, integer);
CREATE OR REPLACE FUNCTION public.set_match_met_answer(
  p_match_id uuid,
  p_met boolean,
  p_repeat_delay_seconds integer
)
RETURNS void AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.matches m
    WHERE m.id = p_match_id AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'not_a_match_participant';
  END IF;

  INSERT INTO public.match_rating_prompts (match_id, user_id, met_answer, met_confirmed, met_answered_at, next_prompt_at)
  VALUES (
    p_match_id,
    auth.uid(),
    p_met,
    p_met,
    now(),
    CASE WHEN p_met THEN NULL ELSE now() + make_interval(secs => p_repeat_delay_seconds) END
  )
  ON CONFLICT (match_id, user_id) DO UPDATE SET
    met_answer = EXCLUDED.met_answer,
    met_confirmed = EXCLUDED.met_confirmed,
    met_answered_at = EXCLUDED.met_answered_at,
    next_prompt_at = EXCLUDED.next_prompt_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.set_match_met_answer(uuid, boolean, integer) TO authenticated;

DROP FUNCTION IF EXISTS public.submit_match_rating(uuid, integer, integer, integer, integer, integer);
CREATE OR REPLACE FUNCTION public.submit_match_rating(
  p_match_id uuid,
  p_q1 integer,
  p_q2 integer,
  p_q3 integer,
  p_q4 integer,
  p_q5 integer
)
RETURNS void AS $$
DECLARE
  v_other uuid;
BEGIN
  SELECT CASE WHEN m.user1_id = auth.uid() THEN m.user2_id ELSE m.user1_id END
    INTO v_other
  FROM public.matches m
  WHERE m.id = p_match_id AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid());

  IF v_other IS NULL THEN
    RAISE EXCEPTION 'not_a_match_participant';
  END IF;

  INSERT INTO public.match_ratings (match_id, rater_id, ratee_id, q1, q2, q3, q4, q5)
  VALUES (p_match_id, auth.uid(), v_other, p_q1, p_q2, p_q3, p_q4, p_q5);

  INSERT INTO public.match_rating_prompts (match_id, user_id, met_answer, met_confirmed, met_answered_at, rating_submitted_at, next_prompt_at)
  VALUES (p_match_id, auth.uid(), true, true, now(), now(), NULL)
  ON CONFLICT (match_id, user_id) DO UPDATE SET
    met_answer = true,
    met_confirmed = true,
    met_answered_at = COALESCE(public.match_rating_prompts.met_answered_at, now()),
    rating_submitted_at = now(),
    next_prompt_at = NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.submit_match_rating(uuid, integer, integer, integer, integer, integer) TO authenticated;

DROP FUNCTION IF EXISTS public.get_user_rating_summary(uuid, integer, integer);
CREATE OR REPLACE FUNCTION public.get_user_rating_summary(
  p_user_id uuid,
  p_min_count integer DEFAULT 0,
  p_last_n integer DEFAULT NULL
)
RETURNS TABLE (
  rated_by_count integer,
  q1_avg double precision,
  q2_avg double precision,
  q3_avg double precision,
  q4_avg double precision,
  q5_avg double precision,
  overall_avg double precision
) AS $$
WITH base AS (
  SELECT *
  FROM public.match_ratings mr
  WHERE mr.ratee_id = p_user_id
  ORDER BY mr.created_at DESC
  LIMIT COALESCE(p_last_n, 2147483647)
),
agg AS (
  SELECT
    COUNT(*)::int AS rated_by_count,
    AVG(q1::double precision) AS q1_avg,
    AVG(q2::double precision) AS q2_avg,
    AVG(q3::double precision) AS q3_avg,
    AVG(q4::double precision) AS q4_avg,
    AVG(q5::double precision) AS q5_avg,
    AVG(((q1 + q2 + q3 + q4 + q5)::double precision) / 5.0) AS overall_avg
  FROM base
)
SELECT
  a.rated_by_count,
  CASE WHEN a.rated_by_count < p_min_count THEN NULL ELSE a.q1_avg END,
  CASE WHEN a.rated_by_count < p_min_count THEN NULL ELSE a.q2_avg END,
  CASE WHEN a.rated_by_count < p_min_count THEN NULL ELSE a.q3_avg END,
  CASE WHEN a.rated_by_count < p_min_count THEN NULL ELSE a.q4_avg END,
  CASE WHEN a.rated_by_count < p_min_count THEN NULL ELSE a.q5_avg END,
  CASE WHEN a.rated_by_count < p_min_count THEN NULL ELSE a.overall_avg END
FROM agg a;
$$ LANGUAGE sql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.get_user_rating_summary(uuid, integer, integer) TO authenticated;

-- =========================
-- 4) app_config seeds (admin-configurable)
-- =========================

INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value, allowed_values)
VALUES
  ('ratings.enabled', 'true', 'boolean', 'ratings', 'Enable match rating prompts and rating UI', false, NULL, NULL, NULL),
  ('ratings.scale_min', '1', 'number', 'ratings', 'Minimum rating value (inclusive)', false, 1, 1, NULL),
  ('ratings.scale_max', '5', 'number', 'ratings', 'Maximum rating value (inclusive)', false, 5, 5, NULL),
  ('ratings.prompt_initial_delay_seconds', '72000', 'duration_seconds', 'ratings', 'Delay after match creation before first meet prompt (default 20 hours)', false, 0, NULL, NULL),
  ('ratings.prompt_repeat_delay_seconds', '259200', 'duration_seconds', 'ratings', 'Delay before re-prompt after user answers no (default 72 hours)', false, 0, NULL, NULL),
  ('ratings.display_min_count', '1', 'number', 'ratings', 'Minimum rating count before showing averages publicly', false, 0, NULL, NULL),
  ('ratings.aggregate_last_n', '100', 'number', 'ratings', 'Optional: average over last N ratings (null/0 means all)', false, 0, NULL, NULL),
  ('ratings.questions',
    '[
      {"id":"communication","translationKey":"ratingQ1Communication","order":1,"enabled":true},
      {"id":"reliability","translationKey":"ratingQ2Reliability","order":2,"enabled":true},
      {"id":"respect","translationKey":"ratingQ3Respect","order":3,"enabled":true},
      {"id":"safety","translationKey":"ratingQ4Safety","order":4,"enabled":true},
      {"id":"profile_accuracy","translationKey":"ratingQ5Accuracy","order":5,"enabled":true}
    ]',
    'array',
    'ratings',
    'Rating questions shown after a match meetup (JSON array of objects with translationKey)',
    false,
    NULL,
    NULL,
    NULL
  )
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value,
  allowed_values = EXCLUDED.allowed_values;

-- =========================
-- 5) translations seeds (en/es/he)
-- =========================

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'ratingPromptTitle', 'Rate your match'),
  ('en', 'ratingPromptBody', 'Did you meet {name} in real life?'),
  ('en', 'ratingPromptYes', 'Yes'),
  ('en', 'ratingPromptNo', 'No'),
  ('en', 'ratingPromptLater', 'Later'),
  ('en', 'ratingScreenTitle', 'Rate {name}'),
  ('en', 'ratingSubmit', 'Submit'),
  ('en', 'ratingThanks', 'Thanks for your feedback'),
  ('en', 'ratingNotEnoughData', 'Not enough ratings yet'),
  ('en', 'ratingRatedBy', 'Rated by {count} users'),
  ('en', 'ratingOverall', 'Final rating'),
  ('en', 'ratingSectionTitle', 'Ratings:'),
  ('en', 'ratingHeaderCommunication', 'Communication'),
  ('en', 'ratingHeaderReliability', 'Reliability'),
  ('en', 'ratingHeaderRespect', 'Respect and Consideration'),
  ('en', 'ratingHeaderSafety', 'Safety and Comfort'),
  ('en', 'ratingHeaderAccuracy', 'Profile Accuracy'),
  ('en', 'ratingQ1Communication', 'How well did this person communicate before and during the meetup?'),
  ('en', 'ratingQ2Reliability', 'How reliable was this person (showed up as planned / on time)?'),
  ('en', 'ratingQ3Respect', 'How respectful and considerate was this person during the meetup?'),
  ('en', 'ratingQ4Safety', 'How safe and comfortable did you feel meeting this person?'),
  ('en', 'ratingQ5Accuracy', 'How accurately did this person’s profile represent them in real life?'),

  ('es', 'ratingPromptTitle', 'Califica a tu match'),
  ('es', 'ratingPromptBody', '¿Te reuniste con {name} en la vida real?'),
  ('es', 'ratingPromptYes', 'Sí'),
  ('es', 'ratingPromptNo', 'No'),
  ('es', 'ratingPromptLater', 'Más tarde'),
  ('es', 'ratingScreenTitle', 'Califica a {name}'),
  ('es', 'ratingSubmit', 'Enviar'),
  ('es', 'ratingThanks', 'Gracias por tus comentarios'),
  ('es', 'ratingNotEnoughData', 'Aún no hay suficientes calificaciones'),
  ('es', 'ratingRatedBy', 'Calificado por {count} usuarios'),
  ('es', 'ratingOverall', 'Calificación final'),
  ('es', 'ratingSectionTitle', 'Calificaciones:'),
  ('es', 'ratingHeaderCommunication', 'Comunicación'),
  ('es', 'ratingHeaderReliability', 'Confiabilidad'),
  ('es', 'ratingHeaderRespect', 'Respeto y consideración'),
  ('es', 'ratingHeaderSafety', 'Seguridad y comodidad'),
  ('es', 'ratingHeaderAccuracy', 'Precisión del perfil'),
  ('es', 'ratingQ1Communication', '¿Qué tan bien se comunicó esta persona antes y durante la reunión?'),
  ('es', 'ratingQ2Reliability', '¿Qué tan confiable fue esta persona (se presentó según lo acordado / a tiempo)?'),
  ('es', 'ratingQ3Respect', '¿Qué tan respetuosa y considerada fue esta persona durante la reunión?'),
  ('es', 'ratingQ4Safety', '¿Qué tan seguro y cómodo te sentiste al reunirte con esta persona?'),
  ('es', 'ratingQ5Accuracy', '¿Qué tan fiel fue el perfil de esta persona a la realidad?'),

  ('he', 'ratingPromptTitle', 'דרג/י את ההתאמה שלך'),
  ('he', 'ratingPromptBody', 'נפגשת עם {name} בחיים האמיתיים?'),
  ('he', 'ratingPromptYes', 'כן'),
  ('he', 'ratingPromptNo', 'לא'),
  ('he', 'ratingPromptLater', 'אחר כך'),
  ('he', 'ratingScreenTitle', 'דרג/י את {name}'),
  ('he', 'ratingSubmit', 'שלח/י'),
  ('he', 'ratingThanks', 'תודה על המשוב'),
  ('he', 'ratingNotEnoughData', 'עדיין אין מספיק דירוגים'),
  ('he', 'ratingRatedBy', 'דורג על ידי {count} משתמשים'),
  ('he', 'ratingOverall', 'דירוג סופי'),
  ('he', 'ratingSectionTitle', 'דירוגים:'),
  ('he', 'ratingHeaderCommunication', 'תקשורת'),
  ('he', 'ratingHeaderReliability', 'אמינות'),
  ('he', 'ratingHeaderRespect', 'כבוד והתחשבות'),
  ('he', 'ratingHeaderSafety', 'בטיחות ונוחות'),
  ('he', 'ratingHeaderAccuracy', 'דיוק בפרופיל'),
  ('he', 'ratingQ1Communication', 'עד כמה האדם הזה תקשר היטב לפני ובמהלך המפגש?'),
  ('he', 'ratingQ2Reliability', 'עד כמה האדם הזה היה אמין (הגיע כפי שסוכם / בזמן)?'),
  ('he', 'ratingQ3Respect', 'עד כמה האדם הזה היה מכבד ומתחשב במהלך המפגש?'),
  ('he', 'ratingQ4Safety', 'עד כמה הרגשת בטוח/ה ונוח/ה להיפגש עם האדם הזה?'),
  ('he', 'ratingQ5Accuracy', 'עד כמה הפרופיל של האדם הזה ייצג אותו/ה בצורה מדויקת במציאות?')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;

