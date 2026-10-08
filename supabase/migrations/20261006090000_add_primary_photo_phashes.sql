-- Migration: Perceptual-hash (dHash) dedupe for primary photo moderation
-- Date: 2026-10-06
-- Depends on: user_profiles.approved_primary_photo_hashes (exact-byte SHA-256
--             dedupe, see 20262090000000_photo_moderation_hash_dedupe.sql)
--
-- Problem: the SHA-256 dedupe only catches byte-identical re-uploads. The
-- same photo re-encoded, recompressed, re-cropped with identical framing, or
-- screenshotted produces different bytes — and a full Gemini round-trip —
-- every time.
--
-- Fix: validate-primary-photo now also stores a 64-bit dHash bit string per
-- approved primary photo and reuses the prior approval when a new upload's
-- Hamming distance to any stored hash is <= 8. Only POSITIVE outcomes are
-- recorded, exactly like the SHA-256 lists.
--
-- The edge function degrades gracefully if this migration has not run yet:
-- the column-select fails, a warning is logged, and only the legacy hash
-- dedupe applies. No backfill needed — new approvals repopulate the list.

ALTER TABLE user_profiles
  ADD COLUMN IF NOT EXISTS approved_primary_photo_phashes text[] NOT NULL DEFAULT '{}';
