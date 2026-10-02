-- Matched attendees for a shared event.
-- Returns the caller's matches (any match_type) who are attending the given
-- event. SECURITY DEFINER is required because RLS only lets users read their
-- own event_attendees rows; the function only exposes attendance status for
-- users the caller already has a match row with, plus masked name and photos
-- (same privacy pattern as get_user_recent_matches).

BEGIN;

CREATE OR REPLACE FUNCTION public.get_event_matched_attendees(p_event_id uuid)
RETURNS TABLE (
  id uuid,
  user1_id uuid,
  user2_id uuid,
  match_type text,
  matched_intent text,
  created_at timestamptz,
  other_name text,
  other_photos text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT m.id,
         m.user1_id,
         m.user2_id,
         m.match_type,
         m.matched_intent,
         m.created_at,
         public.mask_full_name(u.name) AS other_name,
         ARRAY(SELECT jsonb_array_elements_text(COALESCE(up.photos, '[]'::jsonb))) AS other_photos
  FROM public.matches m
  JOIN public.event_attendees ea
    ON ea.event_id = p_event_id
   AND ea.user_id = CASE WHEN m.user1_id = auth.uid() THEN m.user2_id ELSE m.user1_id END
  LEFT JOIN public.users u
    ON u.id = CASE WHEN m.user1_id = auth.uid() THEN m.user2_id ELSE m.user1_id END
  LEFT JOIN public.user_profiles up
    ON up.user_id = CASE WHEN m.user1_id = auth.uid() THEN m.user2_id ELSE m.user1_id END
  WHERE auth.uid() IS NOT NULL
    AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.event_attendees ea_me
      WHERE ea_me.event_id = p_event_id AND ea_me.user_id = auth.uid()
    );
$$;

REVOKE EXECUTE ON FUNCTION public.get_event_matched_attendees(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_event_matched_attendees(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_event_matched_attendees(uuid) TO authenticated;

COMMIT;
