-- Migration: Add get_masked_sender_name RPC
-- Purpose: Provide a single, RLS-bypassing lookup for the masked display name
-- of a chat sender, so push notifications can always show a real name instead
-- of falling back to placeholders like "Someone" or "New message".
--
-- Background:
--   The push-message edge function previously called
--   `user_profiles.profile_data->>'fullName'` directly. That column is hidden
--   by RLS for anon/authenticated and the JSON key is fragile (could be
--   `name`, `full_name`, etc.). SECURITY DEFINER bypasses RLS and we resolve
--   multiple possible storage locations in one place, mirroring the existing
--   `check_unread_notifications` RPC's approach.
--
-- Resolution order:
--   1) public.user_profiles.profile_data->>'fullName'   (preferred display name)
--   2) public.user_profiles.profile_data->>'name'        (alt JSON key)
--   3) public.user_profiles.profile_data->>'displayName' (alt JSON key)
--   4) public.users.name                                 (auth account fallback)
--   5) public.users.full_name                            (auth account alt)
--   6) auth.users.raw_user_meta_data->>'full_name'       (Supabase auth meta)
--   7) auth.users.raw_user_meta_data->>'name'            (Supabase auth meta alt)
--
-- Returns an empty string when no name is found anywhere. The caller is
-- responsible for any final "Someone"-style fallback.

CREATE OR REPLACE FUNCTION public.get_masked_sender_name(p_sender_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_raw text;
BEGIN
  IF p_sender_id IS NULL THEN
    RETURN '';
  END IF;

  -- 1) public.user_profiles.profile_data->>'fullName'
  SELECT NULLIF(btrim(up.profile_data->>'fullName'), '')
    INTO v_raw
    FROM public.user_profiles up
   WHERE up.user_id = p_sender_id;
  IF v_raw IS NOT NULL THEN
    RETURN public.mask_full_name(v_raw);
  END IF;

  -- 2) public.user_profiles.profile_data->>'name'
  SELECT NULLIF(btrim(up.profile_data->>'name'), '')
    INTO v_raw
    FROM public.user_profiles up
   WHERE up.user_id = p_sender_id;
  IF v_raw IS NOT NULL THEN
    RETURN public.mask_full_name(v_raw);
  END IF;

  -- 3) public.user_profiles.profile_data->>'displayName'
  SELECT NULLIF(btrim(up.profile_data->>'displayName'), '')
    INTO v_raw
    FROM public.user_profiles up
   WHERE up.user_id = p_sender_id;
  IF v_raw IS NOT NULL THEN
    RETURN public.mask_full_name(v_raw);
  END IF;

  -- 4) public.users.name
  SELECT NULLIF(btrim(u.name), '')
    INTO v_raw
    FROM public.users u
   WHERE u.id = p_sender_id;
  IF v_raw IS NOT NULL THEN
    RETURN public.mask_full_name(v_raw);
  END IF;

  -- 5) public.users.full_name
  SELECT NULLIF(btrim(u.full_name), '')
    INTO v_raw
    FROM public.users u
   WHERE u.id = p_sender_id;
  IF v_raw IS NOT NULL THEN
    RETURN public.mask_full_name(v_raw);
  END IF;

  -- 6) auth.users.raw_user_meta_data->>'full_name'
  SELECT NULLIF(btrim(au.raw_user_meta_data->>'full_name'), '')
    INTO v_raw
    FROM auth.users au
   WHERE au.id = p_sender_id;
  IF v_raw IS NOT NULL THEN
    RETURN public.mask_full_name(v_raw);
  END IF;

  -- 7) auth.users.raw_user_meta_data->>'name'
  SELECT NULLIF(btrim(au.raw_user_meta_data->>'name'), '')
    INTO v_raw
    FROM auth.users au
   WHERE au.id = p_sender_id;
  IF v_raw IS NOT NULL THEN
    RETURN public.mask_full_name(v_raw);
  END IF;

  RETURN '';
END;
$$;

-- Grant execute to roles the edge function / app might use
GRANT EXECUTE ON FUNCTION public.get_masked_sender_name(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_masked_sender_name(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_masked_sender_name(uuid) TO service_role;
