-- Migration: AI rate limiting (configurable per task via app_config)
-- Date: 2026-10-05
--
-- Every edge function that sends user content to an AI service (Gemini,
-- Cloud Vision, DeepL) consumes quota per identifier (user id, or hashed IP
-- when no user context exists) per task type. Limits are read at runtime by
-- the edge functions from app_config keys:
--
--   ai.rate_limit.<task>.hourly
--   ai.rate_limit.<task>.daily
--
-- Tasks: primary_photo_validation, secondary_photo_validation,
--        verification_face_comparison, bio_moderation, event_file_parse,
--        event_metadata, translation
--
-- A limit of 0 (or negative) disables the gate for that task/window.
-- Rows below are seeded with defaults; the admin app can edit them in
-- app_config. Deleting a row reverts to the built-in defaults.

CREATE TABLE IF NOT EXISTS public.ai_rate_limit_usage (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  identifier TEXT NOT NULL,
  task TEXT NOT NULL,
  window_type TEXT NOT NULL CHECK (window_type IN ('hour', 'day')),
  window_start TIMESTAMPTZ NOT NULL,
  count INTEGER NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (identifier, task, window_type, window_start)
);

ALTER TABLE public.ai_rate_limit_usage ENABLE ROW LEVEL SECURITY;
-- No policies: only service_role (edge functions) may read/write.
REVOKE ALL ON public.ai_rate_limit_usage FROM anon, authenticated;

-- Atomic consume: increments the hour/day counters; when a limit is exceeded
-- the increments are rolled back so denied attempts never consume quota.
CREATE OR REPLACE FUNCTION public.consume_ai_rate_limit(
  p_identifier TEXT,
  p_task TEXT,
  p_hourly_limit INTEGER,
  p_daily_limit INTEGER
)
RETURNS TABLE (allowed BOOLEAN, retry_after_seconds INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_hour_start TIMESTAMPTZ := date_trunc('hour', NOW());
  v_day_start TIMESTAMPTZ := date_trunc('day', NOW());
  v_hour_count INTEGER;
  v_day_count INTEGER;
  v_hour_remaining INTEGER;
  v_day_remaining INTEGER;
BEGIN
  -- Limits <= 0 disable the gate for this task/window.
  IF p_hourly_limit <= 0 AND p_daily_limit <= 0 THEN
    RETURN QUERY SELECT TRUE, 0;
    RETURN;
  END IF;

  INSERT INTO ai_rate_limit_usage (identifier, task, window_type, window_start, count)
  VALUES (p_identifier, p_task, 'hour', v_hour_start, 1)
  ON CONFLICT (identifier, task, window_type, window_start)
  DO UPDATE SET count = ai_rate_limit_usage.count + 1, updated_at = NOW()
  RETURNING count INTO v_hour_count;

  INSERT INTO ai_rate_limit_usage (identifier, task, window_type, window_start, count)
  VALUES (p_identifier, p_task, 'day', v_day_start, 1)
  ON CONFLICT (identifier, task, window_type, window_start)
  DO UPDATE SET count = ai_rate_limit_usage.count + 1, updated_at = NOW()
  RETURNING count INTO v_day_count;

  IF v_hour_count > GREATEST(p_hourly_limit, 0) OR v_day_count > GREATEST(p_daily_limit, 0) THEN
    -- Roll back so denied attempts don't consume quota.
    UPDATE ai_rate_limit_usage SET count = count - 1, updated_at = NOW()
    WHERE identifier = p_identifier AND task = p_task
      AND window_type = 'hour' AND window_start = v_hour_start;
    UPDATE ai_rate_limit_usage SET count = count - 1, updated_at = NOW()
    WHERE identifier = p_identifier AND task = p_task
      AND window_type = 'day' AND window_start = v_day_start;

    v_hour_remaining := GREATEST(0, 3600 - EXTRACT(EPOCH FROM (NOW() - v_hour_start))::INTEGER);
    v_day_remaining := GREATEST(0, 86400 - EXTRACT(EPOCH FROM (NOW() - v_day_start))::INTEGER);

    IF p_hourly_limit > 0 AND v_hour_count > p_hourly_limit THEN
      RETURN QUERY SELECT FALSE, v_hour_remaining;
    ELSE
      RETURN QUERY SELECT FALSE, v_day_remaining;
    END IF;
    RETURN;
  END IF;

  -- Opportunistic cleanup (~1% of calls): drop windows older than 2 days.
  IF random() < 0.01 THEN
    DELETE FROM ai_rate_limit_usage WHERE window_start < NOW() - INTERVAL '2 days';
  END IF;

  RETURN QUERY SELECT TRUE, 0;
END;
$$;

REVOKE ALL ON FUNCTION public.consume_ai_rate_limit FROM anon, authenticated;

-- Seed configurable limits (defaults mirror _shared/ai_rate_limit.ts).
-- app_config is the admin-app-managed table (config_key/config_value JSONB).
INSERT INTO public.app_config (
  config_key,
  config_value,
  config_type,
  category,
  description,
  is_user_configurable,
  min_value,
  max_value
) VALUES
  ('ai.rate_limit.primary_photo_validation.hourly', '20'::jsonb, 'number', 'ai', 'Max primary photo AI validations per user per hour (0 = unlimited)', false, 0, NULL),
  ('ai.rate_limit.primary_photo_validation.daily', '100'::jsonb, 'number', 'ai', 'Max primary photo AI validations per user per day (0 = unlimited)', false, 0, NULL),
  ('ai.rate_limit.secondary_photo_validation.hourly', '40'::jsonb, 'number', 'ai', 'Max secondary photo AI validations per user per hour (0 = unlimited)', false, 0, NULL),
  ('ai.rate_limit.secondary_photo_validation.daily', '200'::jsonb, 'number', 'ai', 'Max secondary photo AI validations per user per day (0 = unlimited)', false, 0, NULL),
  ('ai.rate_limit.verification_face_comparison.hourly', '10'::jsonb, 'number', 'ai', 'Max verification photo AI comparisons per user per hour (0 = unlimited)', false, 0, NULL),
  ('ai.rate_limit.verification_face_comparison.daily', '50'::jsonb, 'number', 'ai', 'Max verification photo AI comparisons per user per day (0 = unlimited)', false, 0, NULL),
  ('ai.rate_limit.bio_moderation.hourly', '30'::jsonb, 'number', 'ai', 'Max bio AI moderations per identifier per hour (0 = unlimited)', false, 0, NULL),
  ('ai.rate_limit.bio_moderation.daily', '150'::jsonb, 'number', 'ai', 'Max bio AI moderations per identifier per day (0 = unlimited)', false, 0, NULL),
  ('ai.rate_limit.event_file_parse.hourly', '10'::jsonb, 'number', 'ai', 'Max event file AI parses per user per hour (0 = unlimited)', false, 0, NULL),
  ('ai.rate_limit.event_file_parse.daily', '30'::jsonb, 'number', 'ai', 'Max event file AI parses per user per day (0 = unlimited)', false, 0, NULL),
  ('ai.rate_limit.event_metadata.hourly', '30'::jsonb, 'number', 'ai', 'Max event metadata/joinability AI calls per identifier per hour (0 = unlimited)', false, 0, NULL),
  ('ai.rate_limit.event_metadata.daily', '150'::jsonb, 'number', 'ai', 'Max event metadata/joinability AI calls per identifier per day (0 = unlimited)', false, 0, NULL),
  ('ai.rate_limit.translation.hourly', '100'::jsonb, 'number', 'ai', 'Max client-initiated DeepL translations per user per hour (0 = unlimited)', false, 0, NULL),
  ('ai.rate_limit.translation.daily', '500'::jsonb, 'number', 'ai', 'Max client-initiated DeepL translations per user per day (0 = unlimited)', false, 0, NULL)
ON CONFLICT (config_key) DO NOTHING;
