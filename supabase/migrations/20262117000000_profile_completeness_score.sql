-- Migration: Profile completeness score
-- Purpose:
--   1. Add a cached 0-100 "richness" score to user_profiles that measures how
--      much OPTIONAL profile content a user has filled in on top of the
--      minimum the wizard already enforces (name+DOB, >=1 photo, interests,
--      business occupation/education).
--   2. Keep it up to date with a BEFORE INSERT OR UPDATE trigger so any write
--      path (client upsert, admin action, backfill) leaves a fresh value.
--
-- Design notes:
--   * Required fields earn partial credit (1-2 photos = 10/20) so every
--     completed profile starts with "endowed progress" (goal-gradient effect).
--   * Items that do not apply to a user's active intents are excluded from
--     BOTH the earned and the maximum, so 100% stays reachable for every
--     intent mix. Applicability mirrors the wizard's ProfileWizardPageMap:
--       - personal interests, lifestyle: social intents (any non-business)
--       - business interests: business intent
--       - family, height: romantic intent
--       - religion: romantic or friendship intent
--   * zodiac_sign is deliberately NOT scored: it is auto-derived for display
--     and never persisted by the wizard.
--
-- IMPORTANT: The Dart mirror of these rules lives in
--   lib/utils/profile_completeness.dart (class ProfileCompleteness).
-- Any change to weights, applicability or done-rules MUST be applied to both
-- sides so the UI and the stored value never disagree.

BEGIN;

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS profile_completeness smallint NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.profile_completeness_score(p public.user_profiles)
RETURNS smallint
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_modes    jsonb := COALESCE(p.active_modes, '[]'::jsonb);
  v_personal jsonb := COALESCE(p.personal_interests, '{}'::jsonb);
  v_business jsonb := COALESCE(p.business_interests, '{}'::jsonb);
  v_langs    jsonb := COALESCE(p.languages_known, '{}'::jsonb);
  v_has_social   boolean := false;
  v_has_business boolean := false;
  v_has_romantic boolean := false;
  v_has_friendship boolean := false;
  v_photo_count  integer := 0;
  v_lang_count   integer := 0;
  v_earned numeric := 0;
  v_max    numeric := 0;
BEGIN
  -- Intent flags (normalization mirrors ProfileWizardPageMap/profile fixups:
  -- lowercase, non-alphanumerics -> '_', collapse and trim underscores).
  IF jsonb_typeof(v_modes) = 'array' THEN
    SELECT
      COALESCE(bool_or(norm <> 'business_networking'), false),
      COALESCE(bool_or(norm = 'business_networking'), false),
      COALESCE(bool_or(norm = 'romantic'), false),
      COALESCE(bool_or(norm = 'friendship'), false)
    INTO v_has_social, v_has_business, v_has_romantic, v_has_friendship
    FROM (
      SELECT trim(both '_' from regexp_replace(
               regexp_replace(lower(trim(m)), '[^a-z0-9]+', '_', 'g'),
               '_+', '_', 'g')) AS norm
      FROM jsonb_array_elements_text(v_modes) AS t(m)
    ) s;
  END IF;

  IF jsonb_typeof(COALESCE(p.photos, '[]'::jsonb)) = 'array' THEN
    v_photo_count := jsonb_array_length(COALESCE(p.photos, '[]'::jsonb));
  END IF;

  IF jsonb_typeof(v_langs) = 'object' THEN
    SELECT count(*) INTO v_lang_count
    FROM jsonb_each(v_langs) AS e(k, val)
    WHERE jsonb_typeof(e.val) = 'array' AND jsonb_array_length(e.val) > 0;
  END IF;

  -- Photos: 20 at 3+; 10 (partial) at 1-2 (the required first photo counts
  -- as endowed progress).
  v_max := v_max + 20;
  IF v_photo_count >= 3 THEN
    v_earned := v_earned + 20;
  ELSIF v_photo_count >= 1 THEN
    v_earned := v_earned + 10;
  END IF;

  -- Bio: 15
  v_max := v_max + 15;
  IF COALESCE(length(trim(p.bio)), 0) > 0 THEN
    v_earned := v_earned + 15;
  END IF;

  -- Personal interests: 5 (social intents only)
  IF v_has_social THEN
    v_max := v_max + 5;
    IF jsonb_typeof(v_personal) = 'object' AND EXISTS (
      SELECT 1 FROM jsonb_each(v_personal) AS e(k, val)
      WHERE jsonb_typeof(e.val) = 'array' AND jsonb_array_length(e.val) > 0
    ) THEN
      v_earned := v_earned + 5;
    END IF;
  END IF;

  -- Business interests: 5 (business intent only)
  IF v_has_business THEN
    v_max := v_max + 5;
    IF jsonb_typeof(v_business) = 'object' AND EXISTS (
      SELECT 1 FROM jsonb_each(v_business) AS e(k, val)
      WHERE jsonb_typeof(e.val) = 'array' AND jsonb_array_length(e.val) > 0
    ) THEN
      v_earned := v_earned + 5;
    END IF;
  END IF;

  -- Lifestyle: 10 (social intents only — the wizard hides the page for
  -- business-only users), when the JSONB object has content.
  IF v_has_social THEN
    v_max := v_max + 10;
    IF jsonb_typeof(p.lifestyle) = 'object' AND p.lifestyle <> '{}'::jsonb THEN
      v_earned := v_earned + 10;
    END IF;
  END IF;

  -- Family: 10 (romantic intent only — wizard hides the page otherwise).
  IF v_has_romantic THEN
    v_max := v_max + 10;
    IF jsonb_typeof(p.family) = 'object' AND p.family <> '{}'::jsonb THEN
      v_earned := v_earned + 10;
    END IF;
  END IF;

  -- Religion: 10 (romantic or friendship intent only).
  IF v_has_romantic OR v_has_friendship THEN
    v_max := v_max + 10;
    IF jsonb_typeof(p.religion) = 'object' AND p.religion <> '{}'::jsonb THEN
      v_earned := v_earned + 10;
    END IF;
  END IF;

  -- Occupation / education: 5 each
  v_max := v_max + 5;
  IF COALESCE(length(trim(p.occupation)), 0) > 0 THEN
    v_earned := v_earned + 5;
  END IF;
  v_max := v_max + 5;
  IF COALESCE(length(trim(p.education)), 0) > 0 THEN
    v_earned := v_earned + 5;
  END IF;

  -- Height: 5 (romantic intents only)
  IF v_has_romantic THEN
    v_max := v_max + 5;
    IF p.height IS NOT NULL THEN
      v_earned := v_earned + 5;
    END IF;
  END IF;

  -- Social links: 5 when at least one is set
  v_max := v_max + 5;
  IF COALESCE(length(trim(p.instagram_url)), 0) > 0
     OR COALESCE(length(trim(p.linkedin_url)), 0) > 0
     OR COALESCE(length(trim(p.facebook_url)), 0) > 0 THEN
    v_earned := v_earned + 5;
  END IF;

  -- Languages: 5 when at least 2 languages have skill entries
  v_max := v_max + 5;
  IF v_lang_count >= 2 THEN
    v_earned := v_earned + 5;
  END IF;

  IF v_max <= 0 THEN
    RETURN 0;
  END IF;
  RETURN round(100 * v_earned / v_max)::smallint;
END;
$$;

-- Trigger keeps the cached column in lock-step with the row. UPDATE OF list
-- covers every column the score reads; the client upsert always sends all of
-- them, so the score also refreshes on plain resaves.
CREATE OR REPLACE FUNCTION public.set_profile_completeness()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.profile_completeness := public.profile_completeness_score(NEW);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_profile_completeness ON public.user_profiles;
CREATE TRIGGER trg_set_profile_completeness
  BEFORE INSERT OR UPDATE OF
    photos, bio, active_modes, personal_interests, business_interests,
    lifestyle, family, religion, occupation, education, height,
    instagram_url, linkedin_url, facebook_url, languages_known
  ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.set_profile_completeness();

-- Backfill existing rows (does not fire the trigger: no scored column is in
-- the SET list).
UPDATE public.user_profiles p
SET profile_completeness = public.profile_completeness_score(p);

COMMIT;
