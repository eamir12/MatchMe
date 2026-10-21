-- Onboarding tour: relabel the verified badge.
--
-- The profile status chips were relabelled in
-- 20262142000000_update_status_badge_labels.sql: only the primary photo is
-- verified, so the chip now reads "Primary Photo Verified" (Spanish:
-- "Foto principal verificada", Hebrew: "תמונה ראשית מאומתת").
--
-- The onboarding narrations still called it the plain "Verified badge", so
-- the tour promised a different badge than the one the app actually shows.
-- The English values below are identical to the built-in fallbacks in
-- lib/providers/locale_provider.dart (the English tour copy is the
-- fallback, so the two must not drift apart); the Spanish and Hebrew
-- values use the same localized badge names as the chips.
--
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run (ON CONFLICT DO UPDATE).

INSERT INTO public.translations (locale, key, value) VALUES
  -- English
  ('en', 'onboardingBeatProfile2', 'You earned a Primary Photo Verified badge by completing the verification procedure from Settings… This badge shows on your profile and whenever others see you.'),
  ('en', 'onboardingBeatSettings5', 'Verification is launched from here… Complete a live selfie check to earn the Primary Photo Verified badge that appears on your profile and when others see you.'),
  ('en', 'onboardingBeatProfileVerifyHint', 'A live selfie check is needed to unlock the Primary Photo Verified badge.'),
  -- Spanish
  ('es', 'onboardingBeatProfile2', 'Ganaste la insignia Foto principal verificada al completar el proceso de verificación desde Ajustes… Esta insignia aparece en tu perfil y siempre que otros te ven.'),
  ('es', 'onboardingBeatSettings5', 'La verificación se lanza desde aquí… Completa una selfie en vivo para ganar la insignia Foto principal verificada que aparece en tu perfil y cuando otros te ven.'),
  ('es', 'onboardingBeatProfileVerifyHint', 'Se necesita una selfie en vivo para desbloquear la insignia Foto principal verificada.'),
  -- Hebrew
  ('he', 'onboardingBeatProfile2', 'קיבלת את תג התמונה הראשית המאומתת בעת השלמת תהליך האימות מתוך ההגדרות… התג מופיע בפרופיל שלך ובכל פעם שאחרים רואים אותך.'),
  ('he', 'onboardingBeatSettings5', 'האימות מופעל מכאן… בצע בדיקת סלפי חיה כדי לזכות בתג התמונה הראשית המאומתת שמופיע בפרופיל שלך וכשאחרים רואים אותך.'),
  ('he', 'onboardingBeatProfileVerifyHint', 'צריך בדיקת סלפי חיה כדי לפתוח את תג התמונה הראשית המאומתת.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
