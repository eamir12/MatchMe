-- Critical Security Fix: admin_update_promo_codes_config Missing Admin Check
-- This function had NO is_admin verification, allowing any authenticated user to modify promo config

DROP FUNCTION IF EXISTS public.admin_update_promo_codes_config(text, jsonb);
DROP FUNCTION IF EXISTS public.admin_update_promo_codes_config(boolean);

CREATE OR REPLACE FUNCTION public.admin_update_promo_codes_config(p_enabled boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
BEGIN
  -- Verify admin role
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  UPDATE public.app_config
  SET config_value = p_enabled::text::jsonb,
      updated_at = NOW()
  WHERE config_key = 'promo_codes_enabled';
END;
$$;

-- Grant execute permission only to authenticated users (but function checks is_admin internally)
GRANT EXECUTE ON FUNCTION public.admin_update_promo_codes_config(boolean) TO authenticated;
