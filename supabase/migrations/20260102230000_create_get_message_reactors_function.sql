-- Migration: Create get_message_reactors function

CREATE OR REPLACE FUNCTION public.get_message_reactors(message_id uuid, reaction text)
RETURNS TABLE(user_id uuid, display_name text, photo text)
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT
    mr.user_id::uuid AS user_id,
    public.mask_full_name(u.name) AS display_name,
    u.photos[1] AS photo
  FROM public.message_reactions mr
  LEFT JOIN public.users u ON u.id = mr.user_id
  WHERE mr.message_id = message_id AND mr.reaction = reaction;
$$;

GRANT EXECUTE ON FUNCTION public.get_message_reactors(uuid, text) TO authenticated;