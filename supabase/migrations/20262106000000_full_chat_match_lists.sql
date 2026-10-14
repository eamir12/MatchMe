-- Migration: full chat/match sync lists + deterministic RPC ordering
--
-- The dedicated Chats and Matches screens read the same Hive cache that the
-- periodic sync fills via get_user_recent_chats / get_user_recent_matches.
-- Both syncs previously paged with app_config sync.recent_items_limit (5),
-- so the cache — and therefore those screens — could never hold more than 5
-- rows, and saveChats actively dropped non-archived cached chats beyond the
-- page on every sync. Home's "Recent" sections cap at 5 in the UI via
-- home.recent_items_limit; the fetch side now uses sync.full_items_limit.
--
-- Ordering: get_user_recent_chats ordered by updated_at DESC alone. A bulk
-- trigger/backfill can stamp every chats row with the same updated_at, making
-- any limited page arbitrary (rows flip in/out between syncs). Order by
-- most-recent activity (last_message_at, falling back to updated_at) with a
-- match_id tiebreaker for a stable page. get_user_recent_matches gets the
-- same tiebreaker on created_at.

BEGIN;

-- 1) Deterministic ordering (column set unchanged from 20262080000000)

DROP FUNCTION IF EXISTS public.get_user_recent_chats(uuid, int);
CREATE OR REPLACE FUNCTION public.get_user_recent_chats(p_user_id uuid, p_limit int DEFAULT 20)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  other_photos text[],
  last_message_preview text,
  last_message_at timestamptz,
  unread_count integer,
  updated_at timestamptz,
  translation_enabled boolean,
  translation_language text,
  last_message_id uuid,
  last_message_sender_id uuid,
  last_message_translated text,
  last_message_source_language text,
  last_message_target_language text,
  last_message_encryption_scheme text,
  last_message_sender_key_id uuid,
  last_message_recipient_key_id uuid,
  last_message_recipient_id uuid,
  last_message_content_original_encrypted text,
  last_message_content_original_nonce text,
  last_message_content_translated_encrypted text,
  last_message_content_translated_nonce text,
  last_message_wrapped_keys jsonb,
  matched_intent text,
  last_message_edited_at timestamptz,
  last_message_translated_source_edited_at timestamptz,
  match_type text,
  archived_at timestamptz
) AS $$
  SELECT c.match_id, c.other_user_id,
         public.mask_full_name(u.name) as other_name,
         ARRAY(SELECT jsonb_array_elements_text(up.photos)) as other_photos,
         c.last_message_preview, c.last_message_at,
         c.unread_count, c.updated_at,
         c.translation_enabled, c.translation_language,
         c.last_message_id,
         COALESCE(cm.sender_id, c.other_user_id) as last_message_sender_id,
         CASE
             WHEN cm.content_translated_encrypted IS NOT NULL
                  AND cm.content_translated_encrypted != ''
             THEN cm.content_translated_encrypted
             ELSE NULL
         END as last_message_translated,
         cm.detected_source_language as last_message_source_language,
         cm.translated_target_language as last_message_target_language,
         cm.encryption_scheme as last_message_encryption_scheme,
         cm.sender_key_id as last_message_sender_key_id,
         cm.recipient_key_id as last_message_recipient_key_id,
         cm.recipient_id as last_message_recipient_id,
         cm.content_original_encrypted as last_message_content_original_encrypted,
         cm.content_original_nonce as last_message_content_original_nonce,
         cm.content_translated_encrypted as last_message_content_translated_encrypted,
         cm.content_translated_nonce as last_message_content_translated_nonce,
         cm.wrapped_keys as last_message_wrapped_keys,
         m.matched_intent as matched_intent,
         cm.edited_at as last_message_edited_at,
         cm.translated_source_edited_at as last_message_translated_source_edited_at,
         m.match_type as match_type,
         c.archived_at as archived_at
  FROM public.chats c
  INNER JOIN public.matches m ON m.id = c.match_id
  LEFT JOIN public.users u ON c.other_user_id = u.id
  LEFT JOIN public.user_profiles up ON up.user_id = c.other_user_id
  LEFT JOIN public.chat_messages cm ON cm.id = c.last_message_id
  WHERE c.user_id = p_user_id
  ORDER BY GREATEST(c.last_message_at, c.updated_at) DESC NULLS LAST,
           c.match_id
  LIMIT p_limit;
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION public.get_user_recent_chats(uuid, int) IS
  'Chats for a user, most recent activity first (last_message_at/updated_at, '
  'match_id tiebreaker for a stable page). archived_at is set when the user '
  'archived the chat; the client splits its list into active and archived '
  'views from this column. Archiving does not mute: message triggers keep '
  'updating the row and notifications flow as normal.';

DROP FUNCTION IF EXISTS public.get_user_recent_matches(uuid, int);
CREATE OR REPLACE FUNCTION public.get_user_recent_matches(p_user_id uuid, p_limit int DEFAULT 20)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  other_photos text[],
  match_type text,
  matched_intent text,
  last_activity_at timestamptz,
  created_at timestamptz,
  chat_start_window_seconds integer,
  chat_start_extension_seconds integer,
  chat_start_extension_count integer,
  expires_at timestamptz,
  has_extended boolean,
  extension_seconds integer,
  match_occurrence integer,
  map_center_lat double precision,
  map_center_lng double precision,
  map_zoom double precision,
  previous_locations jsonb
) AS $$
  SELECT
    m.id as match_id,
    CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END as other_user_id,
    public.mask_full_name(u.name) as other_name,
    ARRAY(SELECT jsonb_array_elements_text(up.photos)) as other_photos,
    m.match_type,
    m.matched_intent,
    m.created_at as last_activity_at,
    m.created_at,
    m.chat_start_window_seconds,
    COALESCE(m.chat_start_extension_seconds, 0) as chat_start_extension_seconds,
    COALESCE(m.chat_start_extension_count, 0) as chat_start_extension_count,
    m.created_at + make_interval(secs => COALESCE(m.chat_start_window_seconds, 86400) + COALESCE(m.chat_start_extension_seconds,0)) as expires_at,
    CASE WHEN p_user_id = m.user1_id THEN COALESCE(m.chat_start_user1_extension_seconds, 0) > 0 ELSE COALESCE(m.chat_start_user2_extension_seconds, 0) > 0 END as has_extended,
    CASE WHEN p_user_id = m.user1_id THEN COALESCE(m.chat_start_user1_extension_seconds, 0) ELSE COALESCE(m.chat_start_user2_extension_seconds, 0) END as extension_seconds,
    COALESCE(m.match_occurrence, 1) as match_occurrence,
    m.map_center_lat,
    m.map_center_lng,
    m.map_zoom,
    COALESCE(up_hist.locations_history, '[]'::jsonb) as previous_locations
  FROM public.matches m
  LEFT JOIN public.users u ON u.id = CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END
  LEFT JOIN public.user_profiles up ON up.user_id = CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END
  LEFT JOIN public.unmatched_pairs up_hist ON up_hist.user1_id = LEAST(m.user1_id, m.user2_id) AND up_hist.user2_id = GREATEST(m.user1_id, m.user2_id)
  WHERE m.user1_id = p_user_id OR m.user2_id = p_user_id
  ORDER BY m.created_at DESC, m.id
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.get_user_recent_chats(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_chats(uuid, int) TO anon;
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, int) TO anon;

-- 2) Config keys
--    sync.full_items_limit: p_limit used by the periodic full sync of chats
--    and matches (default 500 = production safety cap; PostgREST pages have
--    hard row ceilings, and every sync writes the full list to the Hive cache
--    that the Chats/Matches screens read).
--    home.recent_items_limit: how many rows the Home "Recent Chats" and
--    "Recent Matches" preview sections display (UI-side take(N)).
--    sync.recent_items_limit is left in place but no longer read by the
--    client; both new keys supersede it.

INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value, allowed_values)
VALUES
  ('sync.full_items_limit', '500', 'number', 'sync',
   'Max chats/matches fetched per full sync (feeds the local cache backing the Chats and Matches screens)',
   false, 20, 5000, NULL),
  ('home.recent_items_limit', '5', 'number', 'home',
   'Number of rows shown in the Home screen Recent Chats and Recent Matches preview sections',
   false, 1, 50, NULL)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value,
  allowed_values = EXCLUDED.allowed_values;

COMMIT;
