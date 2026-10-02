-- Migration: Localize "Promo Code" payment method label
-- Description: Adds a translation key used to display the promo-code payment
--              method on the Billing screen, so the chip and details row are
--              translated instead of showing the hardcoded English value.

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'billingPaymentMethodPromoCode', 'Promo Code'),
  ('es', 'billingPaymentMethodPromoCode', 'Código promocional'),
  ('he', 'billingPaymentMethodPromoCode', 'קוד הטבה')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
