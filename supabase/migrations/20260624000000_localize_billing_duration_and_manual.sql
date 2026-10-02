-- Migration: Localize "Manual" payment method label on the Billing screen
-- Description: Seeds the billingPaymentMethodManual translation key so the
--              "Manual" payment provider chip renders in the user's locale
--              instead of always showing the hardcoded English fallback.

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'billingPaymentMethodManual', 'Manual'),
  ('es', 'billingPaymentMethodManual', 'Manual'),
  ('he', 'billingPaymentMethodManual', 'ידני')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
