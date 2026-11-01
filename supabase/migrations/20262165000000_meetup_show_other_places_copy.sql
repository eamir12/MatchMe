-- In-person meet-up: "Show other places" paging copy.
--
-- The picker now offers two extra rounds of three from the places the lookup
-- already returned, so this is pure copy: no provider call and no extra quota.
-- The English fallback lives in lib/providers/locale_provider.dart.

INSERT INTO public.translations (locale, key, value) VALUES
('en', 'meetupShowOtherPlaces', 'Show other places'),
('es', 'meetupShowOtherPlaces', 'Mostrar otros lugares'),
('he', 'meetupShowOtherPlaces', 'הצג מקומות אחרים')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
