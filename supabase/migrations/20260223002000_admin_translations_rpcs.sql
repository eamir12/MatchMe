-- Admin-only RPCs for managing translations safely (no direct table writes from clients)

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_bulk_upsert_translations(p_items jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_count integer := 0;
  v_item jsonb;
  v_locale text;
  v_key text;
  v_value text;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'p_items must be a JSON array';
  END IF;

  FOR v_item IN SELECT jsonb_array_elements(p_items)
  LOOP
    v_locale := NULLIF(trim(v_item->>'locale'), '');
    v_key := NULLIF(trim(v_item->>'key'), '');
    v_value := COALESCE(v_item->>'value', '');

    IF v_locale IS NULL OR v_key IS NULL THEN
      CONTINUE;
    END IF;

    IF v_locale NOT IN ('en', 'es', 'he') THEN
      CONTINUE;
    END IF;

    INSERT INTO public.translations (locale, key, value)
    VALUES (v_locale, v_key, v_value)
    ON CONFLICT (locale, key) DO UPDATE
    SET value = EXCLUDED.value;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_translation_key(p_key text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_trimmed_key text;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_trimmed_key := NULLIF(trim(p_key), '');
  IF v_trimmed_key IS NULL THEN
    RAISE EXCEPTION 'p_key is required';
  END IF;

  DELETE FROM public.translations
  WHERE key = v_trimmed_key;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_translation_locale_key(p_locale text, p_key text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_trimmed_locale text;
  v_trimmed_key text;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_trimmed_locale := NULLIF(trim(p_locale), '');
  v_trimmed_key := NULLIF(trim(p_key), '');
  IF v_trimmed_locale IS NULL OR v_trimmed_key IS NULL THEN
    RAISE EXCEPTION 'p_locale and p_key are required';
  END IF;

  DELETE FROM public.translations
  WHERE locale = v_trimmed_locale
    AND key = v_trimmed_key;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_bulk_upsert_translations(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_translation_key(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_translation_locale_key(text, text) TO authenticated;

COMMIT;

