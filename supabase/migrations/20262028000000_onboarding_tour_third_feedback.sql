-- Onboarding tour third feedback round.
--  * Nearby2 now narrates the per-person dots (one dot per online and
--    visible member inside the match circle) instead of the removed
--    showing-count pill; the nearby map shows no counts at all.
--  * Matches1 no longer mentions a % score: matches show a shared-interest
--    count (heart), exactly as on the real match cards.
-- English values intentionally match the built-in fallbacks in
-- locale_provider.dart (later migration wins over earlier seeds).
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run (ON CONFLICT DO UPDATE).

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'onboardingBeatNearby2', 'Each dot is an online and visible member inside your match circle… The blue marker in the middle is you.'),
  ('en', 'onboardingBeatMatches1', 'Every time you and another member want the same kind of connection, they appear here as a match… The heart shows how many interests you share.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'onboardingBeatNearby2', 'Cada punto es un miembro en línea y visible dentro de tu círculo… El marcador azul del centro eres tú.'),
  ('es', 'onboardingBeatMatches1', 'Cada vez que tú y otra persona buscan el mismo tipo de conexión, aparece aquí como una coincidencia… El corazón muestra cuántos intereses comparten.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'onboardingBeatNearby2', 'כל נקודה היא חבר מקוון וגלוי בתוך המעגל שלכם… הסמן הכחול באמצע זה אתם.'),
  ('he', 'onboardingBeatMatches1', 'בכל פעם שאתם ומישהו נוסף מחפשים את אותו סוג קשר, הוא מופיע כאן כהתאמה… הלב מראה כמה תחומי עניין אתם חולקים.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
