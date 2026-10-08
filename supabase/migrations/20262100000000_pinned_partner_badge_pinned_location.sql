-- Migration: Rename pinned-partner badge copy to "Pinned location"
-- Date: 2026-10-07
--
-- The MatchBox redesign turns the old pink "Home base" text line into a
-- uniform signal chip. The chip already carries a push-pin icon, so the copy
-- drops the emoji and says what the pin is: "Pinned location".
-- Upsert is idempotent; safe to re-run.

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'pinnedPartnerBadge', 'Pinned location'),
  ('he', 'pinnedPartnerBadge', 'מיקום נעוץ'),
  ('es', 'pinnedPartnerBadge', 'Ubicación fijada')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value;
