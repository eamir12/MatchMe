-- Migration: Add translations for the profile completeness feature
-- Purpose: All user-facing strings for the owner-facing completeness card,
--   the home feed banner and the public 100% badge come from the translations
--   table (en/es/he). English fallbacks are in
--   lib/providers/locale_provider.dart::_defaultTranslations.
-- Reference: See supabase/migrations/20260831000001_add_match_extension_translations.sql for pattern.

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- English
  ('en', 'profileCompletionTitle', $$Profile completeness$$),
  ('en', 'profileCompletionPercent', $${percent}% complete$$),
  ('en', 'profileCompletionAlmostThere', $$Almost there!$$),
  ('en', 'profileCompletionFullTitle', $$Profile complete$$),
  ('en', 'profileCompletionFullMessage', $$Your profile is 100% complete. Nice work!$$),
  ('en', 'profileCompletionSubtitle', $$Complete profiles get more matches$$),
  ('en', 'profileCompletionNextSteps', $$Next steps$$),
  ('en', 'profileCompletionImprove', $$Complete now$$),
  ('en', 'profileCompletionMoreItems', $$+{count} more$$),
  ('en', 'profileCompletionItemPhotos', $$Add 3 or more photos$$),
  ('en', 'profileCompletionItemBio', $$Write a short bio$$),
  ('en', 'profileCompletionItemPersonalInterests', $$Add personal interests$$),
  ('en', 'profileCompletionItemBusinessInterests', $$Add business interests$$),
  ('en', 'profileCompletionItemLifestyle', $$Add your lifestyle$$),
  ('en', 'profileCompletionItemFamily', $$Add family details$$),
  ('en', 'profileCompletionItemReligion', $$Add religion details$$),
  ('en', 'profileCompletionItemOccupation', $$Add your occupation$$),
  ('en', 'profileCompletionItemEducation', $$Add your education$$),
  ('en', 'profileCompletionItemHeight', $$Add your height$$),
  ('en', 'profileCompletionItemSocial', $$Link a social profile$$),
  ('en', 'profileCompletionItemLanguages', $$Add at least 2 languages$$),
  ('en', 'profileCompletionBadge', $$Complete$$),
  ('en', 'profileCompletionBadgeTooltip', $$This profile is 100% complete$$),
  ('en', 'profileCompletionBannerTitle', $$Complete your profile$$),
  ('en', 'profileCompletionBannerMessage', $${percent}% complete — finish the rest to stand out and get more matches.$$),
  ('en', 'profileCompletionDismiss', $$Dismiss$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Spanish
  ('es', 'profileCompletionTitle', $$Completitud del perfil$$),
  ('es', 'profileCompletionPercent', $${percent}% completado$$),
  ('es', 'profileCompletionAlmostThere', $$¡Casi lo tienes!$$),
  ('es', 'profileCompletionFullTitle', $$Perfil completo$$),
  ('es', 'profileCompletionFullMessage', $$Tu perfil está 100% completo. ¡Buen trabajo!$$),
  ('es', 'profileCompletionSubtitle', $$Los perfiles completos reciben más matches$$),
  ('es', 'profileCompletionNextSteps', $$Próximos pasos$$),
  ('es', 'profileCompletionImprove', $$Completar ahora$$),
  ('es', 'profileCompletionMoreItems', $$+{count} más$$),
  ('es', 'profileCompletionItemPhotos', $$Añade 3 fotos o más$$),
  ('es', 'profileCompletionItemBio', $$Escribe una breve biografía$$),
  ('es', 'profileCompletionItemPersonalInterests', $$Añade intereses personales$$),
  ('es', 'profileCompletionItemBusinessInterests', $$Añade intereses profesionales$$),
  ('es', 'profileCompletionItemLifestyle', $$Añade tu estilo de vida$$),
  ('es', 'profileCompletionItemFamily', $$Añade detalles familiares$$),
  ('es', 'profileCompletionItemReligion', $$Añade detalles de religión$$),
  ('es', 'profileCompletionItemOccupation', $$Añade tu ocupación$$),
  ('es', 'profileCompletionItemEducation', $$Añade tu educación$$),
  ('es', 'profileCompletionItemHeight', $$Añade tu altura$$),
  ('es', 'profileCompletionItemSocial', $$Vincula una red social$$),
  ('es', 'profileCompletionItemLanguages', $$Añade al menos 2 idiomas$$),
  ('es', 'profileCompletionBadge', $$Completo$$),
  ('es', 'profileCompletionBadgeTooltip', $$Este perfil está 100% completo$$),
  ('es', 'profileCompletionBannerTitle', $$Completa tu perfil$$),
  ('es', 'profileCompletionBannerMessage', $${percent}% completado: completa el resto para destacar y recibir más matches.$$),
  ('es', 'profileCompletionDismiss', $$Descartar$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Hebrew
  ('he', 'profileCompletionTitle', $$שלמות הפרופיל$$),
  ('he', 'profileCompletionPercent', $${percent}% הושלמו$$),
  ('he', 'profileCompletionAlmostThere', $$כמעט שם!$$),
  ('he', 'profileCompletionFullTitle', $$הפרופיל מלא$$),
  ('he', 'profileCompletionFullMessage', $$הפרופיל שלך מלא ב-100%. כל הכבוד!$$),
  ('he', 'profileCompletionSubtitle', $$פרופילים מלאים מקבלים יותר התאמות$$),
  ('he', 'profileCompletionNextSteps', $$השלבים הבאים$$),
  ('he', 'profileCompletionImprove', $$השלם עכשיו$$),
  ('he', 'profileCompletionMoreItems', $$+{count} נוספים$$),
  ('he', 'profileCompletionItemPhotos', $$הוסף 3 תמונות או יותר$$),
  ('he', 'profileCompletionItemBio', $$כתוב ביוגרפיה קצרה$$),
  ('he', 'profileCompletionItemPersonalInterests', $$הוסף תחומי עניין אישיים$$),
  ('he', 'profileCompletionItemBusinessInterests', $$הוסף תחומי עניין עסקיים$$),
  ('he', 'profileCompletionItemLifestyle', $$הוסף את אורח החיים שלך$$),
  ('he', 'profileCompletionItemFamily', $$הוסף פרטי משפחה$$),
  ('he', 'profileCompletionItemReligion', $$הוסף פרטי דת$$),
  ('he', 'profileCompletionItemOccupation', $$הוסף את העיסוק שלך$$),
  ('he', 'profileCompletionItemEducation', $$הוסף את ההשכלה שלך$$),
  ('he', 'profileCompletionItemHeight', $$הוסף את הגובה שלך$$),
  ('he', 'profileCompletionItemSocial', $$קשר פרופיל חברתי$$),
  ('he', 'profileCompletionItemLanguages', $$הוסף לפחות 2 שפות$$),
  ('he', 'profileCompletionBadge', $$מלא$$),
  ('he', 'profileCompletionBadgeTooltip', $$הפרופיל הזה מלא ב-100%$$),
  ('he', 'profileCompletionBannerTitle', $$השלם את הפרופיל שלך$$),
  ('he', 'profileCompletionBannerMessage', $${percent}% הושלמו — השלם את השאר כדי לבלוט ולקבל יותר התאמות.$$),
  ('he', 'profileCompletionDismiss', $$סגור$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
