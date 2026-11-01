-- Migration: drop the legacy 3-arg _match_extended_text overload.
--
-- Why: 20262073000000 created public._match_extended_text(text, text, text).
-- 20262074000000 then ran CREATE OR REPLACE with a 4th parameter
-- (p_gender text DEFAULT NULL). CREATE OR REPLACE with a different parameter
-- list creates a NEW overload in Postgres — it does not replace the old one —
-- so the database ended up with BOTH:
--
--   _match_extended_text(text, text, text)                  (20262073)
--   _match_extended_text(text, text, text, text DEFAULT NULL) (20262074)
--
-- Every 3-arg call whose 2nd/3rd arguments are string literals (type
-- "unknown", e.g. _match_extended_text(v_locale, 'key', 'fallback')) then
-- matches both overloads equally and Postgres raises:
--
--   function public._match_extended_text(text, unknown, unknown) is not unique
--
-- Each affected function swallows that error in an EXCEPTION handler that
-- only RAISE WARNINGs and skips the alert, so the partner never receives the
-- inbox row / push. Affected (all silently failing since 20262074 was
-- applied):
--
--   notify_meetup_session        (20262161 — the warning seen in postgres
--                                 logs: meetup proposal / place-change alerts)
--   notify_meetup_signal         (20262160 — beacon + wave alerts)
--   notify_meetup_spot           (20262160 — Spot-me-card alerts)
--   notify_location_share_started(20261001020000 — live-location share alerts)
--   notify_match_extended        (20262074 — body call is 3-arg; title passes
--                                 the gender so it resolves; extension RPC
--                                 itself succeeds thanks to its WARNING
--                                 wrapper in extend_match_chat_window)
--
-- Fix: drop the 3-arg overload. All existing 3-arg callers then resolve to
-- the 4-arg version, where the DEFAULT NULL gender skips the variant lookup —
-- identical behavior to the original 3-arg function. 4-arg callers (gendered
-- notify_match_extended title, 20262075 backfill) are unaffected.

-- Pre-check (informational): expect BOTH signatures before the drop.
SELECT p.oid::regprocedure AS signature
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = '_match_extended_text'
ORDER BY 1;

DROP FUNCTION IF EXISTS public._match_extended_text(text, text, text);

-- Post-check: expect exactly ONE signature —
-- public._match_extended_text(text,text,text,text)
SELECT p.oid::regprocedure AS signature
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = '_match_extended_text'
ORDER BY 1;

-- Smoke test: a 3-arg call with string literals must now resolve uniquely
-- (no "is not unique" error) and return the seeded Hebrew proposal title.
SELECT public._match_extended_text('he', 'meetupProposalPushTitle', '📍 {name}')
  AS resolved_title;
