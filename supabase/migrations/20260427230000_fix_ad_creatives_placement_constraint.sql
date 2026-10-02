-- Fix ad_creatives placement constraint to allow all 5 placements including profile_inline
-- This fixes the issue where ads were not showing on chats, events, and profile screens

BEGIN;

-- Drop the existing constraint and add a new one with all 5 placements
ALTER TABLE public.ad_creatives
  DROP CONSTRAINT IF EXISTS ad_creatives_placement_check;

ALTER TABLE public.ad_creatives
  ADD CONSTRAINT ad_creatives_placement_check
  CHECK (placement IN ('home_inline', 'matches_inline', 'chats_inline', 'events_inline', 'profile_inline'));

COMMIT;
