BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminSponsoredAdsReportSummaryTimes', 'Times reported'),
  ('es', 'adminSponsoredAdsReportSummaryTimes', 'Veces reportado'),
  ('he', 'adminSponsoredAdsReportSummaryTimes', 'מספר הדיווחים'),

  ('en', 'adminSponsoredAdsReportSummaryUsers', 'Reporting users'),
  ('es', 'adminSponsoredAdsReportSummaryUsers', 'Usuarios que reportaron'),
  ('he', 'adminSponsoredAdsReportSummaryUsers', 'משתמשים שדיווחו'),

  ('en', 'adminSponsoredAdsReportSummaryLastReported', 'Last reported'),
  ('es', 'adminSponsoredAdsReportSummaryLastReported', 'Ultimo reporte'),
  ('he', 'adminSponsoredAdsReportSummaryLastReported', 'דווח לאחרונה'),

  ('en', 'adminSponsoredAdsReportSummaryLatestReason', 'Latest reason'),
  ('es', 'adminSponsoredAdsReportSummaryLatestReason', 'Motivo mas reciente'),
  ('he', 'adminSponsoredAdsReportSummaryLatestReason', 'הסיבה האחרונה'),

  ('en', 'adminSponsoredAdsReportSummaryLatestPlacement', 'Latest placement'),
  ('es', 'adminSponsoredAdsReportSummaryLatestPlacement', 'Ubicacion mas reciente'),
  ('he', 'adminSponsoredAdsReportSummaryLatestPlacement', 'מיקום אחרון'),

  ('en', 'adminSponsoredAdsReportViewDetails', 'View report details'),
  ('es', 'adminSponsoredAdsReportViewDetails', 'Ver detalles de reportes'),
  ('he', 'adminSponsoredAdsReportViewDetails', 'צפה בפרטי הדיווחים'),

  ('en', 'adminSponsoredAdsReportDialogTitle', 'Report details'),
  ('es', 'adminSponsoredAdsReportDialogTitle', 'Detalles de reportes'),
  ('he', 'adminSponsoredAdsReportDialogTitle', 'פרטי דיווחים'),

  ('en', 'adminSponsoredAdsReportDialogSubtitle', '{count} reports from {users} users'),
  ('es', 'adminSponsoredAdsReportDialogSubtitle', '{count} reportes de {users} usuarios'),
  ('he', 'adminSponsoredAdsReportDialogSubtitle', '{count} דיווחים מ-{users} משתמשים'),

  ('en', 'adminSponsoredAdsReportReporterFallback', 'Unknown user'),
  ('es', 'adminSponsoredAdsReportReporterFallback', 'Usuario desconocido'),
  ('he', 'adminSponsoredAdsReportReporterFallback', 'משתמש לא ידוע'),

  ('en', 'adminSponsoredAdsReportDetailsFallback', 'No additional details provided.'),
  ('es', 'adminSponsoredAdsReportDetailsFallback', 'No se proporcionaron detalles adicionales.'),
  ('he', 'adminSponsoredAdsReportDetailsFallback', 'לא סופקו פרטים נוספים.'),

  ('en', 'adminSponsoredAdsEnableAction', 'Enable'),
  ('es', 'adminSponsoredAdsEnableAction', 'Habilitar'),
  ('he', 'adminSponsoredAdsEnableAction', 'הפעל'),

  ('en', 'adminSponsoredAdsDisableAction', 'Disable'),
  ('es', 'adminSponsoredAdsDisableAction', 'Deshabilitar'),
  ('he', 'adminSponsoredAdsDisableAction', 'השבת')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
