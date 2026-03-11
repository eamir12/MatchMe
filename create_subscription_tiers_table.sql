-- Create subscription_tiers table
CREATE TABLE IF NOT EXISTS public.subscription_tiers (
    id TEXT PRIMARY KEY,
    revenue_cat_package_identifier TEXT NOT NULL,
    title_key TEXT NOT NULL,
    subtitle_key TEXT,
    features_key TEXT NOT NULL, -- Key used to fetch a list of features from translations or a JSON array of keys
    badge_key TEXT, -- e.g., 'bestValue'
    sort_order INTEGER DEFAULT 0,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable RLS
ALTER TABLE public.subscription_tiers ENABLE ROW LEVEL SECURITY;

-- Create policy for public read access (idempotent)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'subscription_tiers'
      AND policyname = 'Allow public read access to subscription_tiers'
  ) THEN
    CREATE POLICY "Allow public read access to subscription_tiers"
      ON public.subscription_tiers
      FOR SELECT
      USING (true);
  END IF;
END $$;

-- Insert default tiers (Example data - Adjust identifiers as needed)
INSERT INTO public.subscription_tiers (id, revenue_cat_package_identifier, title_key, subtitle_key, features_key, badge_key, sort_order, is_active)
VALUES
    ('plus', 'matchme_plus_monthly', 'tierPlusTitle', 'tierPlusSubtitle', 'tierPlusFeatures', NULL, 10, true),
    ('gold', 'matchme_gold_monthly', 'tierGoldTitle', 'tierGoldSubtitle', 'tierGoldFeatures', 'tierBadgeBestValue', 20, true),
    ('platinum', 'matchme_platinum_monthly', 'tierPlatinumTitle', 'tierPlatinumSubtitle', 'tierPlatinumFeatures', 'tierBadgePopular', 30, true)
ON CONFLICT (id) DO NOTHING;

-- Insert translation keys for the new tiers (English, Spanish, Hebrew)

INSERT INTO public.translations (key, value, locale)
VALUES
    -- ENGLISH (en)
    ('tierPlusTitle', 'MatchMe Plus', 'en'),
    ('tierPlusSubtitle', 'Stand out from the crowd', 'en'),
    ('tierPlusFeatures', '["Unlimited Likes", "Rewind last swipe", "5 Super Likes a day"]', 'en'),
    ('tierGoldTitle', 'MatchMe Gold', 'en'),
    ('tierGoldSubtitle', 'See who likes you', 'en'),
    ('tierGoldFeatures', '["See who likes you", "Unlimited Likes", "Rewind", "5 Super Likes", "1 Boost a month"]', 'en'),
    ('tierPlatinumTitle', 'MatchMe Platinum', 'en'),
    ('tierPlatinumSubtitle', 'Prioritized likes', 'en'),
    ('tierPlatinumFeatures', '["Priority Likes", "Message before matching", "See who likes you", "Unlimited Likes"]', 'en'),
    ('tierBadgeBestValue', 'Best Value', 'en'),
    ('tierBadgePopular', 'Most Popular', 'en'),
    
    ('paywallTitle', 'MatchMe Premium', 'en'),
    ('paywallWebError', 'Premium subscriptions are currently only available on the mobile app.', 'en'),
    ('paywallFeaturesTitle', 'Unlock everything', 'en'),
    ('paywallRestore', 'Restore Purchases', 'en'),
    ('paywallTerms', 'Terms of Service', 'en'),
    ('paywallPrivacy', 'Privacy Policy', 'en'),
    ('paywallSubscribe', 'Subscribe', 'en'),
    ('paywallPeriodMonthly', 'Monthly', 'en'),
    ('paywallPeriodAnnual', 'Annual', 'en'),
    ('paywallPeriodWeekly', 'Weekly', 'en'),
    ('paywallPeriodLifetime', 'Lifetime', 'en'),
    ('paywallSavePercent', 'Save {percent}%', 'en'),
    ('durationDay', '{count} day', 'en'),
    ('durationDays', '{count} days', 'en'),
    ('durationHour', '{count} hour', 'en'),
    ('durationHours', '{count} hours', 'en'),
    ('durationMinute', '{count} minute', 'en'),
    ('durationMinutes', '{count} minutes', 'en'),
    ('durationLessThanOneMinute', '< 1 minute', 'en'),

    -- SPANISH (es)
    ('tierPlusTitle', 'MatchMe Plus', 'es'),
    ('tierPlusSubtitle', 'Destaca entre la multitud', 'es'),
    ('tierPlusFeatures', '["Likes ilimitados", "Rebobinar último swipe", "5 Super Likes al día"]', 'es'),
    ('tierGoldTitle', 'MatchMe Gold', 'es'),
    ('tierGoldSubtitle', 'Mira a quién le gustas', 'es'),
    ('tierGoldFeatures', '["Mira a quién le gustas", "Likes ilimitados", "Rebobinar", "5 Super Likes", "1 Boost al mes"]', 'es'),
    ('tierPlatinumTitle', 'MatchMe Platinum', 'es'),
    ('tierPlatinumSubtitle', 'Likes prioritarios', 'es'),
    ('tierPlatinumFeatures', '["Likes prioritarios", "Mensaje antes de hacer match", "Mira a quién le gustas", "Likes ilimitados"]', 'es'),
    ('tierBadgeBestValue', 'Mejor valor', 'es'),
    ('tierBadgePopular', 'Más popular', 'es'),

    ('paywallTitle', 'MatchMe Premium', 'es'),
    ('paywallWebError', 'Las suscripciones Premium solo están disponibles en la aplicación móvil.', 'es'),
    ('paywallFeaturesTitle', 'Desbloquea todo', 'es'),
    ('paywallRestore', 'Restaurar compras', 'es'),
    ('paywallTerms', 'Términos de servicio', 'es'),
    ('paywallPrivacy', 'Política de privacidad', 'es'),
    ('paywallSubscribe', 'Suscribirse', 'es'),
    ('paywallPeriodMonthly', 'Mensual', 'es'),
    ('paywallPeriodAnnual', 'Anual', 'es'),
    ('paywallPeriodWeekly', 'Semanal', 'es'),
    ('paywallPeriodLifetime', 'De por vida', 'es'),
    ('paywallSavePercent', 'Ahorra {percent}%', 'es'),
    ('durationDay', '{count} día', 'es'),
    ('durationDays', '{count} días', 'es'),
    ('durationHour', '{count} hora', 'es'),
    ('durationHours', '{count} horas', 'es'),
    ('durationMinute', '{count} minuto', 'es'),
    ('durationMinutes', '{count} minutos', 'es'),
    ('durationLessThanOneMinute', '< 1 minuto', 'es'),

    -- HEBREW (he)
    ('tierPlusTitle', 'MatchMe Plus', 'he'),
    ('tierPlusSubtitle', 'בלוט מעל כולם', 'he'),
    ('tierPlusFeatures', '["לייקים ללא הגבלה", "ביטול החלקה אחרונה", "5 סופר-לייקים ביום"]', 'he'),
    ('tierGoldTitle', 'MatchMe Gold', 'he'),
    ('tierGoldSubtitle', 'ראה מי אהב אותך', 'he'),
    ('tierGoldFeatures', '["ראה מי אהב אותך", "לייקים ללא הגבלה", "ביטול החלקה", "5 סופר-לייקים", "בוסט אחד בחודש"]', 'he'),
    ('tierPlatinumTitle', 'MatchMe Platinum', 'he'),
    ('tierPlatinumSubtitle', 'לייקים בעדיפות', 'he'),
    ('tierPlatinumFeatures', '["לייקים בעדיפות", "הודעה לפני התאמה", "ראה מי אהב אותך", "לייקים ללא הגבלה"]', 'he'),
    ('tierBadgeBestValue', 'המשתלם ביותר', 'he'),
    ('tierBadgePopular', 'הפופולרי ביותר', 'he'),

    ('paywallTitle', 'MatchMe Premium', 'he'),
    ('paywallWebError', 'מנויי פרימיום זמינים כרגע רק באפליקציה לנייד.', 'he'),
    ('paywallFeaturesTitle', 'פתח את הכל', 'he'),
    ('paywallRestore', 'שחזר רכישות', 'he'),
    ('paywallTerms', 'תנאי שימוש', 'he'),
    ('paywallPrivacy', 'מדיניות פרטיות', 'he'),
    ('paywallSubscribe', 'הירשם', 'he'),
    ('paywallPeriodMonthly', 'חודשי', 'he'),
    ('paywallPeriodAnnual', 'שנתי', 'he'),
    ('paywallPeriodWeekly', 'שבועי', 'he'),
    ('paywallPeriodLifetime', 'לכל החיים', 'he'),
    ('paywallSavePercent', 'חסוך {percent}%', 'he'),
    ('durationDay', '{count} יום', 'he'),
    ('durationDays', '{count} ימים', 'he'),
    ('durationHour', '{count} שעה', 'he'),
    ('durationHours', '{count} שעות', 'he'),
    ('durationMinute', '{count} דקה', 'he'),
    ('durationMinutes', '{count} דקות', 'he'),
    ('durationLessThanOneMinute', '< 1 דקה', 'he')

ON CONFLICT (key, locale) DO UPDATE SET
    value = EXCLUDED.value;

-- ---------------------------------------------------------------------------
-- Subscription state (stored on public.users)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'subscription_expires_at'
  ) THEN
    ALTER TABLE public.users ADD COLUMN subscription_expires_at TIMESTAMPTZ;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'subscription_next_tier'
  ) THEN
    ALTER TABLE public.users ADD COLUMN subscription_next_tier TEXT;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'subscription_next_starts_at'
  ) THEN
    ALTER TABLE public.users ADD COLUMN subscription_next_starts_at TIMESTAMPTZ;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'subscription_next_expires_at'
  ) THEN
    ALTER TABLE public.users ADD COLUMN subscription_next_expires_at TIMESTAMPTZ;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_users_subscription_expires_at ON public.users (subscription_expires_at);

-- ---------------------------------------------------------------------------
-- RPC helpers (client calls these via Supabase RPC)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clear_user_subscription(p_user_id uuid DEFAULT auth.uid())
RETURNS TABLE (
  subscription_tier text,
  subscription_expires_at timestamptz,
  subscription_next_tier text,
  subscription_next_starts_at timestamptz,
  subscription_next_expires_at timestamptz
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_user_id IS NULL THEN
    p_user_id := auth.uid();
  END IF;

  IF p_user_id IS DISTINCT FROM auth.uid()
     AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  UPDATE public.users
  SET subscription_tier = 'free',
      subscription_expires_at = NULL,
      subscription_next_tier = NULL,
      subscription_next_starts_at = NULL,
      subscription_next_expires_at = NULL
  WHERE id = p_user_id;

  RETURN QUERY
  SELECT u.subscription_tier, u.subscription_expires_at, u.subscription_next_tier, u.subscription_next_starts_at, u.subscription_next_expires_at
  FROM public.users u
  WHERE u.id = p_user_id;
END $$;

CREATE OR REPLACE FUNCTION public.normalize_user_subscription(p_user_id uuid DEFAULT auth.uid())
RETURNS TABLE (
  subscription_tier text,
  subscription_expires_at timestamptz,
  subscription_next_tier text,
  subscription_next_starts_at timestamptz,
  subscription_next_expires_at timestamptz
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tier text;
  v_exp timestamptz;
  v_next_tier text;
  v_next_start timestamptz;
  v_next_exp timestamptz;
  v_now timestamptz := now();
BEGIN
  IF p_user_id IS NULL THEN
    p_user_id := auth.uid();
  END IF;

  IF p_user_id IS DISTINCT FROM auth.uid()
     AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  SELECT u.subscription_tier, u.subscription_expires_at, u.subscription_next_tier, u.subscription_next_starts_at, u.subscription_next_expires_at
  INTO v_tier, v_exp, v_next_tier, v_next_start, v_next_exp
  FROM public.users u
  WHERE u.id = p_user_id
  FOR UPDATE;

  IF v_tier IS NULL OR v_tier = '' THEN
    v_tier := 'free';
  END IF;

  IF v_tier <> 'free' AND v_exp IS NOT NULL AND v_exp <= v_now THEN
    IF v_next_tier IS NOT NULL AND v_next_exp IS NOT NULL AND (v_next_start IS NULL OR v_next_start <= v_now) THEN
      v_tier := v_next_tier;
      v_exp := v_next_exp;
      v_next_tier := NULL;
      v_next_start := NULL;
      v_next_exp := NULL;
    ELSE
      v_tier := 'free';
      v_exp := NULL;
      v_next_tier := NULL;
      v_next_start := NULL;
      v_next_exp := NULL;
    END IF;

    UPDATE public.users
    SET subscription_tier = v_tier,
        subscription_expires_at = v_exp,
        subscription_next_tier = v_next_tier,
        subscription_next_starts_at = v_next_start,
        subscription_next_expires_at = v_next_exp
    WHERE id = p_user_id;
  END IF;

  RETURN QUERY SELECT v_tier, v_exp, v_next_tier, v_next_start, v_next_exp;
END $$;

CREATE OR REPLACE FUNCTION public.apply_manual_subscription_purchase(
  p_tier text,
  p_duration_seconds int,
  p_user_id uuid DEFAULT auth.uid()
) RETURNS TABLE (
  subscription_tier text,
  subscription_expires_at timestamptz,
  subscription_next_tier text,
  subscription_next_starts_at timestamptz,
  subscription_next_expires_at timestamptz
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tier text;
  v_exp timestamptz;
  v_next_tier text;
  v_next_start timestamptz;
  v_next_exp timestamptz;
  v_now timestamptz := now();
  v_add interval;
BEGIN
  IF p_user_id IS NULL THEN
    p_user_id := auth.uid();
  END IF;

  IF p_user_id IS DISTINCT FROM auth.uid()
     AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_tier IS NULL OR btrim(p_tier) = '' OR p_tier = 'free' THEN
    RETURN QUERY SELECT * FROM public.clear_user_subscription(p_user_id);
    RETURN;
  END IF;

  v_add := make_interval(secs => GREATEST(COALESCE(p_duration_seconds, 0), 0));

  SELECT u.subscription_tier, u.subscription_expires_at, u.subscription_next_tier, u.subscription_next_starts_at, u.subscription_next_expires_at
  INTO v_tier, v_exp, v_next_tier, v_next_start, v_next_exp
  FROM public.users u
  WHERE u.id = p_user_id
  FOR UPDATE;

  IF v_tier IS NULL OR v_tier = '' THEN
    v_tier := 'free';
  END IF;

  IF v_tier <> 'free' AND v_exp IS NOT NULL AND v_exp > v_now THEN
    IF v_tier = p_tier THEN
      v_exp := v_exp + v_add;
      v_next_tier := NULL;
      v_next_start := NULL;
      v_next_exp := NULL;
    ELSE
      v_next_tier := p_tier;
      v_next_start := v_exp;
      v_next_exp := v_exp + v_add;
    END IF;
  ELSE
    v_tier := p_tier;
    v_exp := v_now + v_add;
    v_next_tier := NULL;
    v_next_start := NULL;
    v_next_exp := NULL;
  END IF;

  UPDATE public.users
  SET subscription_tier = v_tier,
      subscription_expires_at = v_exp,
      subscription_next_tier = v_next_tier,
      subscription_next_starts_at = v_next_start,
      subscription_next_expires_at = v_next_exp
  WHERE id = p_user_id;

  RETURN QUERY SELECT v_tier, v_exp, v_next_tier, v_next_start, v_next_exp;
END $$;

CREATE OR REPLACE FUNCTION public.apply_revenuecat_subscription(
  p_tier text,
  p_expires_at timestamptz,
  p_user_id uuid DEFAULT auth.uid()
) RETURNS TABLE (
  subscription_tier text,
  subscription_expires_at timestamptz,
  subscription_next_tier text,
  subscription_next_starts_at timestamptz,
  subscription_next_expires_at timestamptz
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tier text;
  v_exp timestamptz;
BEGIN
  IF p_user_id IS NULL THEN
    p_user_id := auth.uid();
  END IF;

  IF p_user_id IS DISTINCT FROM auth.uid()
     AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_tier IS NULL OR btrim(p_tier) = '' OR p_tier = 'free' OR p_expires_at IS NULL OR p_expires_at <= now() THEN
    v_tier := 'free';
    v_exp := NULL;
  ELSE
    v_tier := p_tier;
    v_exp := p_expires_at;
  END IF;

  UPDATE public.users
  SET subscription_tier = v_tier,
      subscription_expires_at = v_exp,
      subscription_next_tier = NULL,
      subscription_next_starts_at = NULL,
      subscription_next_expires_at = NULL
  WHERE id = p_user_id;

  RETURN QUERY
  SELECT u.subscription_tier, u.subscription_expires_at, u.subscription_next_tier, u.subscription_next_starts_at, u.subscription_next_expires_at
  FROM public.users u
  WHERE u.id = p_user_id;
END $$;

GRANT EXECUTE ON FUNCTION public.clear_user_subscription(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.normalize_user_subscription(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_manual_subscription_purchase(text, int, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_revenuecat_subscription(text, timestamptz, uuid) TO authenticated;
