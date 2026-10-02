BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminSponsoredAdsUnsavedTitle', 'Save changes?'),
  ('es', 'adminSponsoredAdsUnsavedTitle', 'Guardar cambios?'),
  ('he', 'adminSponsoredAdsUnsavedTitle', 'לשמור שינויים?'),

  ('en', 'adminSponsoredAdsUnsavedBody', 'You have unsaved ad changes. Save them before leaving the editor?'),
  ('es', 'adminSponsoredAdsUnsavedBody', 'Tienes cambios no guardados en el anuncio. Quieres guardarlos antes de salir del editor?'),
  ('he', 'adminSponsoredAdsUnsavedBody', 'יש לך שינויים שלא נשמרו במודעה. לשמור אותם לפני היציאה מהעורך?'),

  ('en', 'adminSponsoredAdsUnsavedDiscard', 'Discard changes'),
  ('es', 'adminSponsoredAdsUnsavedDiscard', 'Descartar cambios'),
  ('he', 'adminSponsoredAdsUnsavedDiscard', 'בטל שינויים'),

  ('en', 'adminSponsoredAdsDisabledBannerTitle', 'Ad system is disabled'),
  ('es', 'adminSponsoredAdsDisabledBannerTitle', 'El sistema de anuncios esta deshabilitado'),
  ('he', 'adminSponsoredAdsDisabledBannerTitle', 'מערכת המודעות מושבתת'),

  ('en', 'adminSponsoredAdsDisabledBannerBody', 'Changes here will not go live until {enabledLabel} is turned back on in {controlsLabel}.'),
  ('es', 'adminSponsoredAdsDisabledBannerBody', 'Los cambios aqui no estaran activos hasta que {enabledLabel} vuelva a activarse en {controlsLabel}.'),
  ('he', 'adminSponsoredAdsDisabledBannerBody', 'שינויים כאן לא יעלו לאוויר עד ש-{enabledLabel} יופעל מחדש ב-{controlsLabel}.')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
