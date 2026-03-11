INSERT INTO public.translations (locale, key, value) VALUES
('en', 'paywallPeriodDaily', 'Daily'),
('es', 'paywallPeriodDaily', 'Diario'),
('he', 'paywallPeriodDaily', 'יומי')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
