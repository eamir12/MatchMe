BEGIN;

DROP FUNCTION IF EXISTS public.admin_upsert_subscription_tier(text, text, text, text, text, text, int, boolean);
CREATE OR REPLACE FUNCTION public.admin_upsert_subscription_tier(
  p_id text,
  p_revenue_cat_package_identifier text,
  p_title_key text,
  p_subtitle_key text,
  p_features_key text,
  p_badge_key text,
  p_sort_order int,
  p_is_active boolean
)
RETURNS public.subscription_tiers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.subscription_tiers;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_id IS NULL OR btrim(p_id) = '' THEN
    RAISE EXCEPTION 'tier id is required';
  END IF;

  IF p_revenue_cat_package_identifier IS NULL OR btrim(p_revenue_cat_package_identifier) = '' THEN
    RAISE EXCEPTION 'revenue_cat_package_identifier is required';
  END IF;

  IF p_title_key IS NULL OR btrim(p_title_key) = '' THEN
    RAISE EXCEPTION 'title_key is required';
  END IF;

  IF p_features_key IS NULL OR btrim(p_features_key) = '' THEN
    RAISE EXCEPTION 'features_key is required';
  END IF;

  INSERT INTO public.subscription_tiers (
    id,
    revenue_cat_package_identifier,
    title_key,
    subtitle_key,
    features_key,
    badge_key,
    sort_order,
    is_active
  ) VALUES (
    p_id,
    p_revenue_cat_package_identifier,
    p_title_key,
    NULLIF(btrim(COALESCE(p_subtitle_key, '')), ''),
    p_features_key,
    NULLIF(btrim(COALESCE(p_badge_key, '')), ''),
    COALESCE(p_sort_order, 0),
    COALESCE(p_is_active, true)
  )
  ON CONFLICT (id) DO UPDATE SET
    revenue_cat_package_identifier = EXCLUDED.revenue_cat_package_identifier,
    title_key = EXCLUDED.title_key,
    subtitle_key = EXCLUDED.subtitle_key,
    features_key = EXCLUDED.features_key,
    badge_key = EXCLUDED.badge_key,
    sort_order = EXCLUDED.sort_order,
    is_active = EXCLUDED.is_active;

  SELECT *
  INTO v_row
  FROM public.subscription_tiers st
  WHERE st.id = p_id;

  RETURN v_row;
END;
$$;

DROP FUNCTION IF EXISTS public.admin_delete_subscription_tier(text);
CREATE OR REPLACE FUNCTION public.admin_delete_subscription_tier(p_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_id IS NULL OR btrim(p_id) = '' THEN
    RAISE EXCEPTION 'tier id is required';
  END IF;

  DELETE FROM public.subscription_tiers st
  WHERE st.id = p_id;
END;
$$;

DROP FUNCTION IF EXISTS public.admin_upsert_subscription_plan(text, text, text, text, text, text, int);
CREATE OR REPLACE FUNCTION public.admin_upsert_subscription_plan(
  p_id text,
  p_tier_id text,
  p_duration text,
  p_price_display text,
  p_savings_text text,
  p_revenue_cat_package_identifier text,
  p_sort_order int
)
RETURNS public.subscription_plans
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.subscription_plans;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_id IS NULL OR btrim(p_id) = '' THEN
    RAISE EXCEPTION 'plan id is required';
  END IF;

  IF p_tier_id IS NULL OR btrim(p_tier_id) = '' THEN
    RAISE EXCEPTION 'tier_id is required';
  END IF;

  IF p_duration IS NULL OR btrim(p_duration) = '' THEN
    RAISE EXCEPTION 'duration is required';
  END IF;

  IF p_price_display IS NULL OR btrim(p_price_display) = '' THEN
    RAISE EXCEPTION 'price_display is required';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.subscription_tiers st WHERE st.id = p_tier_id) THEN
    RAISE EXCEPTION 'unknown tier_id';
  END IF;

  INSERT INTO public.subscription_plans (
    id,
    tier_id,
    duration,
    price_display,
    savings_text,
    revenue_cat_package_identifier,
    sort_order
  ) VALUES (
    p_id,
    p_tier_id,
    p_duration,
    p_price_display,
    NULLIF(btrim(COALESCE(p_savings_text, '')), ''),
    NULLIF(btrim(COALESCE(p_revenue_cat_package_identifier, '')), ''),
    COALESCE(p_sort_order, 0)
  )
  ON CONFLICT (id) DO UPDATE SET
    tier_id = EXCLUDED.tier_id,
    duration = EXCLUDED.duration,
    price_display = EXCLUDED.price_display,
    savings_text = EXCLUDED.savings_text,
    revenue_cat_package_identifier = EXCLUDED.revenue_cat_package_identifier,
    sort_order = EXCLUDED.sort_order;

  SELECT *
  INTO v_row
  FROM public.subscription_plans sp
  WHERE sp.id = p_id;

  RETURN v_row;
END;
$$;

DROP FUNCTION IF EXISTS public.admin_delete_subscription_plan(text);
CREATE OR REPLACE FUNCTION public.admin_delete_subscription_plan(p_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_id IS NULL OR btrim(p_id) = '' THEN
    RAISE EXCEPTION 'plan id is required';
  END IF;

  DELETE FROM public.subscription_plans sp
  WHERE sp.id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_upsert_subscription_tier(text, text, text, text, text, text, int, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_subscription_tier(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_subscription_plan(text, text, text, text, text, text, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_subscription_plan(text) TO authenticated;

COMMIT;
