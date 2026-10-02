BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminSponsoredAdsImpressionsDialogTitle', 'Impression details'),
  ('es', 'adminSponsoredAdsImpressionsDialogTitle', 'Detalles de impresiones'),
  ('he', 'adminSponsoredAdsImpressionsDialogTitle', 'פרטי חשיפות'),

  ('en', 'adminSponsoredAdsClicksDialogTitle', 'Click details'),
  ('es', 'adminSponsoredAdsClicksDialogTitle', 'Detalles de clics'),
  ('he', 'adminSponsoredAdsClicksDialogTitle', 'פרטי קליקים'),

  ('en', 'adminSponsoredAdsReportsDialogTitle', 'Report details'),
  ('es', 'adminSponsoredAdsReportsDialogTitle', 'Detalles de reportes'),
  ('he', 'adminSponsoredAdsReportsDialogTitle', 'פרטי דיווחים'),

  ('en', 'adminSponsoredAdsMetricUniqueUsers', 'Unique users'),
  ('es', 'adminSponsoredAdsMetricUniqueUsers', 'Usuarios unicos'),
  ('he', 'adminSponsoredAdsMetricUniqueUsers', 'משתמשים ייחודיים'),

  ('en', 'adminSponsoredAdsMetricLastEvent', 'Last event'),
  ('es', 'adminSponsoredAdsMetricLastEvent', 'Ultimo evento'),
  ('he', 'adminSponsoredAdsMetricLastEvent', 'אירוע אחרון'),

  ('en', 'adminSponsoredAdsEventPlacement', 'Placement'),
  ('es', 'adminSponsoredAdsEventPlacement', 'Ubicacion'),
  ('he', 'adminSponsoredAdsEventPlacement', 'מיקום'),

  ('en', 'adminSponsoredAdsEventPlatform', 'Platform'),
  ('es', 'adminSponsoredAdsEventPlatform', 'Plataforma'),
  ('he', 'adminSponsoredAdsEventPlatform', 'פלטפורמה'),

  ('en', 'adminSponsoredAdsEventLocale', 'Locale'),
  ('es', 'adminSponsoredAdsEventLocale', 'Idioma'),
  ('he', 'adminSponsoredAdsEventLocale', 'שפה'),

  ('en', 'adminSponsoredAdsEventDestinationUrl', 'Destination URL'),
  ('es', 'adminSponsoredAdsEventDestinationUrl', 'URL de destino'),
  ('he', 'adminSponsoredAdsEventDestinationUrl', 'כתובת יעד'),

  ('en', 'adminSponsoredAdsEventReason', 'Reason'),
  ('es', 'adminSponsoredAdsEventReason', 'Motivo'),
  ('he', 'adminSponsoredAdsEventReason', 'סיבה'),

  ('en', 'adminSponsoredAdsEventDetails', 'Details'),
  ('es', 'adminSponsoredAdsEventDetails', 'Detalles'),
  ('he', 'adminSponsoredAdsEventDetails', 'פרטים'),

  ('en', 'adminSponsoredAdsEventNoData', 'No details found.'),
  ('es', 'adminSponsoredAdsEventNoData', 'No se encontraron detalles.'),
  ('he', 'adminSponsoredAdsEventNoData', 'לא נמצאו פרטים.'),

  ('en', 'adminSponsoredAdsReportUsersDialogTitle', 'Reporting users'),
  ('es', 'adminSponsoredAdsReportUsersDialogTitle', 'Usuarios que reportaron'),
  ('he', 'adminSponsoredAdsReportUsersDialogTitle', 'משתמשים שדיווחו'),

  ('en', 'adminSponsoredAdsReportLastDialogTitle', 'Last report'),
  ('es', 'adminSponsoredAdsReportLastDialogTitle', 'Ultimo reporte'),
  ('he', 'adminSponsoredAdsReportLastDialogTitle', 'הדיווח האחרון')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
