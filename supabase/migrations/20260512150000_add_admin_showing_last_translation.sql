-- Add translation key for "showing last N" in admin sponsored ads drilldown
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminSponsoredAdsShowingLast', $${total} (showing last {count})$$),
  ('es', 'adminSponsoredAdsShowingLast', $${total} (mostrando últimos {count})$$),
  ('he', 'adminSponsoredAdsShowingLast', $${total} ({count} אחרונים)$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
