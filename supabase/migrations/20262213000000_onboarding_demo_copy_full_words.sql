-- Onboarding demo fixture: the mock card spelled nothing out.
--
-- The tour's fake profile card showed "2 km", "23h", "SAT"/"SUN" and, in
-- Hebrew, "2 ק״מ", "23 שע׳" and "א׳" for Sunday. The values are hard-coded
-- demo copy, so the fix is the words themselves: the radius and the countdown
-- name their unit, and the day chips say Saturday and Sunday.
--
-- Hebrew already reads שבת for Saturday — a full word, not the א׳–ת׳ letter
-- shorthand — so only its Sunday row changes. The English and Spanish rows also
-- have to agree with the fallbacks bundled in lib/providers/locale_provider.dart
-- (test/onboarding/onboarding_translation_parity_test.dart pins them together),
-- which is why these keys are in a migration whose name contains "onboarding":
-- that check only reads files named that way.

INSERT INTO public.translations (locale, key, value) VALUES
('en', 'onboardingDemoRadius', '2 kilometers'),
('es', 'onboardingDemoRadius', '2 kilómetros'),
('he', 'onboardingDemoRadius', '2 קילומטרים'),
('en', 'onboardingDemoTimeLeft', '23 hours'),
('es', 'onboardingDemoTimeLeft', '23 horas'),
('he', 'onboardingDemoTimeLeft', '23 שעות'),
('en', 'onboardingDemoDaySat', 'Saturday'),
('es', 'onboardingDemoDaySat', 'sábado'),
('en', 'onboardingDemoDaySun', 'Sunday'),
('es', 'onboardingDemoDaySun', 'domingo'),
('he', 'onboardingDemoDaySun', 'ראשון')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
