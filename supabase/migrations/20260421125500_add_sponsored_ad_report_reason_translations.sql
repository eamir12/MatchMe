BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminSponsoredAdsReportReasonUserReported', 'Reported by user'),
  ('es', 'adminSponsoredAdsReportReasonUserReported', 'Reportado por un usuario'),
  ('he', 'adminSponsoredAdsReportReasonUserReported', 'דווח על ידי משתמש')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
