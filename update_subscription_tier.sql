CREATE OR REPLACE FUNCTION update_subscription_tier(p_tier text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.users
  SET subscription_tier = p_tier
  WHERE id = auth.uid();
END;
$$;
