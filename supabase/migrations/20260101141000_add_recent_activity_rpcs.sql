-- Migration: RPCs to fetch recent matches and recent chats for a user

BEGIN;

-- get_user_recent_matches: returns recent matches for a user with basic other-user info
CREATE OR REPLACE FUNCTION public.get_user_recent_matches(p_user_id uuid, p_limit int DEFAULT 20)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  other_photos text[],
  match_type text,
  matched_intent text,
  last_activity_at timestamptz,
  created_at timestamptz
) AS $$
  SELECT urm.match_id,
         urm.other_user_id,
         public.mask_full_name(u.name) as other_name,
         u.photos::text[] as other_photos,
         urm.match_type,
         urm.matched_intent,
         urm.last_activity_at,
         urm.created_at
  FROM public.user_recent_matches urm
  LEFT JOIN public.users u ON u.id = urm.other_user_id
  WHERE urm.user_id = p_user_id
  ORDER BY urm.last_activity_at DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE;

-- get_user_recent_chats: returns recent chats for a user with other-user info and unread counts
CREATE OR REPLACE FUNCTION public.get_user_recent_chats(p_user_id uuid, p_limit int DEFAULT 20)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  other_photos text[],
  last_message_id uuid,
  last_message_preview text,
  last_message_at timestamptz,
  unread_count integer,
  last_activity_at timestamptz
) AS $$
  SELECT urc.match_id,
         urc.other_user_id,
         public.mask_full_name(u.name) as other_name,
         u.photos::text[] as other_photos,
         urc.last_message_id,
         urc.last_message_preview,
         urc.last_message_at,
         urc.unread_count,
         urc.last_activity_at
  FROM public.user_recent_chats urc
  LEFT JOIN public.users u ON u.id = urc.other_user_id
  WHERE urc.user_id = p_user_id
  ORDER BY urc.last_activity_at DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE;

COMMIT;
