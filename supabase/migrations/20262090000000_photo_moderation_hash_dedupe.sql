-- Migration: Content-hash dedupe for AI photo moderation
-- Date: 2026-10-05
-- Depends on: user_profiles.approved_primary_photos (array of approved
--             primary-photo storage paths, written by validate-primary-photo)
--
-- Problem: photo approval is keyed by storage PATH, so re-uploading the same
-- image bytes under a new object path (gallery re-add, re-onboarding, the
-- client's "clean" re-encode pipeline) triggers a full Gemini validation
-- round-trip every time. During Gemini capacity spikes those round-trips are
-- also what users experience as "Unable to verify your photo right now".
--
-- Fix: validate-primary-photo / validate-secondary-photo now SHA-256 the
-- downloaded photo bytes and check per-user approved-hash lists BEFORE calling
-- any AI. A hit reuses the prior decision (instant, free) and, for primary
-- photos, appends the new path to approved_primary_photos. Fresh approvals
-- record their hash.
--
-- Hashes are intentionally per-kind (primary vs secondary rules differ: a
-- photo acceptable as a gallery photo is not necessarily acceptable as a
-- face-only primary), and only POSITIVE outcomes are recorded — rejected
-- photos are always re-evaluated so improved models/prompts can rehabilitate
-- them.
--
-- No backfill: existing approvals are path-keyed only; they will repopulate
-- the hash lists naturally the next time the same bytes pass validation.

ALTER TABLE user_profiles
  ADD COLUMN IF NOT EXISTS approved_primary_photo_hashes text[] NOT NULL DEFAULT '{}';

ALTER TABLE user_profiles
  ADD COLUMN IF NOT EXISTS approved_secondary_photo_hashes text[] NOT NULL DEFAULT '{}';
