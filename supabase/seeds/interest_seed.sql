-- supabase/seeds/interest_seed.sql
-- Seed data for interest_categories and interest_items
-- Run in Supabase SQL editor or via psql connected to your DB.

BEGIN;

-- Categories: intent-specific categories use intent_id where possible
-- For this seed we assume intents table contains keys: 'business_networking', 'romantic', 'friendship', 'activity_partner'
-- If your intents are different, adjust category/intent mapping accordingly.

-- Business / Networking categories
INSERT INTO public.interest_categories (category_key, category_display_key, category_sort_order, is_social)
VALUES
  ('business_events', 'Business Events', 10, false),
  ('networking_meetups', 'Networking Meetups', 20, false),
  ('mentoring', 'Mentorship', 30, false)
ON CONFLICT DO NOTHING;

-- Shared social categories (used by Romantic, Friendship, Activity Partner)
INSERT INTO public.interest_categories (category_key, category_display_key, category_sort_order, is_social)
VALUES
  ('dancing', 'Dancing', 100, true),
  ('live_music', 'Live Music', 110, true),
  ('board_games', 'Board Games', 120, true),
  ('fitness', 'Fitness', 130, true)
ON CONFLICT DO NOTHING;

-- Interest items (children). These reference a category_key column.
-- Business / networking items
INSERT INTO public.interest_items (interest_key, interest_display_key, interest_sort_order, category_key)
VALUES
  ('panel_discussions', 'Panel Discussions', 10, 'business_events'),
  ('pitch_sessions', 'Pitch Sessions', 20, 'business_events'),
  ('industry_roundtables', 'Industry Roundtables', 30, 'networking_meetups'),
  ('coffee_meetups', 'Coffee Meetups', 40, 'networking_meetups'),
  ('one_on_one_mentoring', 'One-on-one Mentoring', 10, 'mentoring'),
  ('group_mentoring', 'Group Mentoring', 20, 'mentoring')
ON CONFLICT DO NOTHING;

-- Shared social items
INSERT INTO public.interest_items (interest_key, interest_display_key, interest_sort_order, category_key)
VALUES
  ('dancing_salsa', 'Salsa', 10, 'dancing'),
  ('dancing_cuban', 'Cuban Salsa', 20, 'dancing'),
  ('live_music_jazz', 'Jazz', 10, 'live_music'),
  ('board_games_strategy', 'Strategy Board Games', 10, 'board_games'),
  ('fitness_group_classes', 'Group Classes', 10, 'fitness')
ON CONFLICT DO NOTHING;

-- Link business categories to the business_networking intent via metadata.intent_keys
-- Ensure a metadata column exists to store JSON attributes (some schemas lack this column)
ALTER TABLE public.interest_categories
  ADD COLUMN IF NOT EXISTS metadata jsonb DEFAULT '{}'::jsonb;

UPDATE public.interest_categories
SET metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('intent_keys', jsonb_build_array(to_jsonb('business_networking'::text)))
WHERE category_key IN ('business_events', 'networking_meetups', 'mentoring');

COMMIT;
