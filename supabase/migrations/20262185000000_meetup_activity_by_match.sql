-- Match-box meet-up activity indicator.
--
-- One read-only aggregate row per match for the signed-in user: which of the
-- five meet-up tools is live or pending, whether it needs them or is their own
-- reminder, the chosen place label when the meet-up is active, how many
-- distinct tools are active, and the nearest expiry.
--
-- Live/pending only. Ended sessions and expired signals/spot cards never
-- appear, so this is not a "last used" history.
--
-- Priority (lower wins):
--    1 their place-change request
--    2 their meeting-point proposal
--    3 their live location
--    4 their beacon
--    5 their Spot me card
--    6 their Signal (wave)
--    7 an active meet-up (shared state)
--    8 your live location
--    9 your beacon
--   10 your Spot me card
--   11 your pending proposal
--   12 your pending place change
--   13 your Signal (wave)
--
-- tool_count counts distinct tools (meeting point, live location, Signal,
-- beacon, Spot me), so both sides using the same tool counts once and +N never
-- double-counts.
--
-- All statements are idempotent.

BEGIN;

-- DELETE events must carry the old row so Realtime can evaluate the
-- participant RLS policy; without this, "sharing stopped" can be missed.
ALTER TABLE public.location_share_signals REPLICA IDENTITY FULL;

-- The check-card version of this function shipped without top_label, and
-- CREATE OR REPLACE cannot change an OUT parameter row type (42P13). Drop and
-- recreate inside the same transaction; grants are re-applied below.
DROP FUNCTION IF EXISTS public.meetup_activity_by_match();

CREATE OR REPLACE FUNCTION public.meetup_activity_by_match()
RETURNS TABLE (
  match_id UUID,
  top_kind TEXT,
  top_own BOOLEAN,
  top_label TEXT,
  tool_count INTEGER,
  next_expiry TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH me AS (
    SELECT auth.uid() AS uid
  ),
  my_matches AS (
    SELECT m.id AS match_id
    FROM public.matches m
    CROSS JOIN me
    WHERE me.uid IS NOT NULL
      AND (m.user1_id = me.uid OR m.user2_id = me.uid)
  ),
  candidates AS (
    -- Meeting point: pending change, pending proposal, or active meet-up.
    SELECT
      s.match_id,
      CASE
        WHEN s.status = 'active' AND s.pending_landmark_id IS NOT NULL
          THEN 'place_change'
        WHEN s.status = 'proposed' THEN 'proposal'
        ELSE 'active'
      END AS kind,
      CASE
        WHEN s.status = 'active' AND s.pending_landmark_id IS NOT NULL
          THEN s.pending_change_by = me.uid
        WHEN s.status = 'proposed' THEN s.proposed_by = me.uid
        ELSE FALSE
      END AS own,
      CASE
        WHEN s.status = 'active' AND s.pending_landmark_id IS NULL
          THEN chosen.label
        ELSE NULL
      END AS top_label,
      CASE
        WHEN s.status = 'active' AND s.pending_landmark_id IS NOT NULL THEN
          CASE WHEN s.pending_change_by = me.uid THEN 12 ELSE 1 END
        WHEN s.status = 'proposed' THEN
          CASE WHEN s.proposed_by = me.uid THEN 11 ELSE 2 END
        ELSE 7
      END AS priority,
      'meeting' AS tool,
      s.expires_at AS expires_at
    FROM public.meetup_sessions s
    JOIN my_matches mm ON mm.match_id = s.match_id
    LEFT JOIN public.meetup_landmarks chosen
      ON chosen.id = s.chosen_landmark_id
    CROSS JOIN me
    WHERE s.status IN ('proposed', 'active')
      AND s.expires_at > now()

    UNION ALL

    -- Signals are match-scoped and live without a session.
    SELECT
      sig.match_id,
      sig.type,
      sig.sender_id = me.uid,
      NULL::TEXT AS top_label,
      CASE
        WHEN sig.sender_id <> me.uid AND sig.type = 'beacon' THEN 4
        WHEN sig.sender_id <> me.uid AND sig.type = 'wave' THEN 6
        WHEN sig.sender_id = me.uid AND sig.type = 'beacon' THEN 9
        ELSE 13
      END AS priority,
      CASE WHEN sig.type = 'beacon' THEN 'beacon' ELSE 'signal' END AS tool,
      sig.expires_at
    FROM public.meetup_signals sig
    JOIN my_matches mm ON mm.match_id = sig.match_id
    CROSS JOIN me
    WHERE sig.expires_at > now()

    UNION ALL

    -- Spot me cards. Hidden or deleted cards are not in use for either side.
    SELECT
      c.match_id,
      'spot' AS kind,
      c.sender_id = me.uid AS own,
      NULL::TEXT AS top_label,
      CASE WHEN c.sender_id <> me.uid THEN 5 ELSE 10 END AS priority,
      'spot' AS tool,
      c.expires_at
    FROM public.meetup_spot_cards c
    JOIN my_matches mm ON mm.match_id = c.match_id
    CROSS JOIN me
    WHERE c.deleted_at IS NULL
      AND c.hidden_at IS NULL
      AND c.expires_at > now()

    UNION ALL

    -- Live location: row existence is the sharing state.
    SELECT
      m2.id AS match_id,
      'live' AS kind,
      lss.sharer_id = me.uid AS own,
      NULL::TEXT AS top_label,
      CASE WHEN lss.sharer_id <> me.uid THEN 3 ELSE 8 END AS priority,
      'live' AS tool,
      lss.expires_at
    FROM public.location_share_signals lss
    JOIN public.matches m2 ON m2.id::text = lss.match_id
    JOIN my_matches mm ON mm.match_id = m2.id
    CROSS JOIN me
    WHERE lss.expires_at IS NULL OR lss.expires_at > now()
  ),
  ranked AS (
    SELECT
      candidates.match_id,
      candidates.kind,
      candidates.own,
      candidates.top_label,
      candidates.tool,
      candidates.expires_at,
      ROW_NUMBER() OVER (
        PARTITION BY candidates.match_id
        ORDER BY candidates.priority, candidates.own
      ) AS position
    FROM candidates
  ),
  totals AS (
    SELECT
      candidates.match_id,
      COUNT(DISTINCT candidates.tool)::INTEGER AS tool_count,
      MIN(candidates.expires_at) AS next_expiry
    FROM candidates
    GROUP BY candidates.match_id
  )
  SELECT
    ranked.match_id,
    ranked.kind,
    ranked.own,
    ranked.top_label,
    totals.tool_count,
    totals.next_expiry
  FROM ranked
  JOIN totals ON totals.match_id = ranked.match_id
  WHERE ranked.position = 1;
$$;

REVOKE ALL ON FUNCTION public.meetup_activity_by_match() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_activity_by_match() TO authenticated;

-- ---------------------------------------------------------------------------
-- UI copy for the match-card banner (en/es/he)
-- ---------------------------------------------------------------------------

INSERT INTO public.translations (locale, key, value) VALUES
('en','meetupActivityHintProposal','Choose a place together'),
('en','meetupActivityHintProposalMine','They have been notified'),
('en','meetupActivityHintPlaceChangeMine','You can withdraw it any time'),
('en','meetupActivityHintLive','Open the map to see where they are'),
('en','meetupActivityHintLiveMine','You can stop sharing at any time'),
('en','meetupActivityHintSpotMine','They can see it until it expires'),
('en','meetupActivityHintWaveMine','They can wave back'),
('en','meetupActivityHintActive','Open the meet-up for the tools'),
('en','meetupActivityYourWave','You waved'),
('en','meetupActivityOneMoreTool','1 more meet-up tool is active'),
('en','meetupActivityMoreTools','{count} more meet-up tools are active'),

('es','meetupActivityHintProposal','Elijan un punto de encuentro'),
('es','meetupActivityHintProposalMine','Se notificó a la otra persona'),
('es','meetupActivityHintPlaceChangeMine','Puedes retirarla cuando quieras'),
('es','meetupActivityHintLive','Abre el mapa para ver dónde está'),
('es','meetupActivityHintLiveMine','Puedes dejar de compartir en cualquier momento'),
('es','meetupActivityHintSpotMine','La verá hasta que expire'),
('es','meetupActivityHintWaveMine','Puede saludarte de vuelta'),
('es','meetupActivityHintActive','Abre el encuentro para usar las herramientas'),
('es','meetupActivityYourWave','Saludaste'),
('es','meetupActivityOneMoreTool','1 herramienta de encuentro más está activa'),
('es','meetupActivityMoreTools','{count} herramientas de encuentro más están activas'),

('he','meetupActivityHintProposal','בחרו יחד נקודת מפגש'),
('he','meetupActivityHintProposalMine','הצד השני קיבל התראה'),
('he','meetupActivityHintPlaceChangeMine','אפשר לבטל בכל רגע'),
('he','meetupActivityHintLive','פתחו את המפה כדי לראות איפה הם'),
('he','meetupActivityHintLiveMine','אפשר להפסיק לשתף בכל רגע'),
('he','meetupActivityHintSpotMine','הם יראו אותה עד שהיא תפוג'),
('he','meetupActivityHintWaveMine','הם יכולים לנפנף חזרה'),
('he','meetupActivityHintActive','פתחו את המפגש לכלים'),
('he','meetupActivityYourWave','ניפנפתם'),
('he','meetupActivityOneMoreTool','כלי מפגש נוסף אחד פעיל'),
('he','meetupActivityMoreTools','עוד {count} כלי מפגש פעילים')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
