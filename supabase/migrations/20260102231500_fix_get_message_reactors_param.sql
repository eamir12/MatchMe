-- Migration: Fix get_message_reactors parameter comparison

-- Replace the function body to reference parameters by position to avoid
-- ambiguity between column names and parameter names (e.g., reaction).

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
  WHERE mr.message_id = $1 AND mr.reaction = $2;
$$;

GRANT EXECUTE ON FUNCTION public.get_message_reactors(uuid, text) TO authenticated;
