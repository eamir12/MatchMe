-- Onboarding tour sixth feedback round: the three-matching-modes text belongs
-- to the Matching beat, not the Verification beat.
-- Root cause: the full-sync seed put the three-modes narration under
-- the Settings5 key, whose highlight is the Profile Verification row — and
-- later updates only ever reworded the Spanish/Hebrew copies of other keys,
-- so es/he (and any DB missing the 20262024 update) still speak "three
-- matching modes" while Verification is spotlighted.
--  * Settings2 (Matching highlight) keeps its text and gains the three
--    modes sentences, in addition to what exists there now.
--  * Settings5 (Verification highlight) is re-asserted as verification-only
--    in all three locales.
-- English values intentionally match the built-in fallbacks in
-- locale_provider.dart (later migration wins over earlier seeds).
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run (ON CONFLICT DO UPDATE).

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'onboardingBeatSettings2', 'Under Matching, you control the search distance and the matching modes. Tap to see all matching controls in one place. Three matching modes shape your experience… Shared Event Matching finds people at the same event, Retro Matching finds people you crossed paths with offline, and Background Matching keeps searching while you are away.'),
  ('en', 'onboardingBeatSettings5', 'Verification is launched from here… Complete a live selfie check to earn the Verified badge that appears on your profile and when others see you.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'onboardingBeatSettings2', 'En Coincidencias, controlas la distancia de búsqueda, la compatibilidad en segundo plano y la compatibilidad retro. Toca para ver todos los controles de coincidencia en un lugar. Tres modos dan forma a tu experiencia… La búsqueda por evento compartido encuentra personas en el mismo evento, la búsqueda retro encuentra personas con las que te cruzaste sin conexión, y la búsqueda en segundo plano sigue buscando mientras estás fuera.'),
  ('es', 'onboardingBeatSettings5', 'La verificación se lanza desde aquí… Completa una selfie en vivo para ganar la insignia de Verificado que aparece en tu perfil y cuando otros te ven.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'onboardingBeatSettings2', 'תחת ההתאמות, אתם שולטים בטווח החיפוש, ההתאמה ברקע וההתאמה הרטרו. הקישו כדי לראות את כל בקרות ההתאמה במקום אחד. שלושה מצבים מעצבים את החוויה… חיפוש באירוע משותף מוצא אנשים באותו אירוע, חיפוש רטרו מוצא אנשים שחלפתם על פניהם במצב לא מקוון, וחיפוש ברקע ממשיך לחפש בזמן שאתם לא כאן.'),
  ('he', 'onboardingBeatSettings5', 'האימות מופעל מכאן… השלימו בדיקת סלפי חיה כדי לזכות בתג המאומת שמופיע בפרופיל שלכם וכשאחרים רואים אתכם.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
