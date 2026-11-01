-- Meet-up hub "Get noticed" card copy.
--
-- Signal, Beacon and Spot me now share one compact card, and the Plan and Live
-- location cards hide their explanations behind a details toggle. The English
-- fallback lives in lib/providers/locale_provider.dart; these rows keep en/es/he
-- aligned so the hub never mixes a translated title with an English tooltip.

INSERT INTO public.translations (locale, key, value) VALUES
('en', 'meetupHubNoticedTitle', 'Get noticed'),
('es', 'meetupHubNoticedTitle', 'Que te vean'),
('he', 'meetupHubNoticedTitle', 'שיבחינו בכם'),
('en', 'meetupHubDetailsShow', 'Show details'),
('es', 'meetupHubDetailsShow', 'Ver detalles'),
('he', 'meetupHubDetailsShow', 'להציג פרטים'),
('en', 'meetupHubDetailsHide', 'Hide details'),
('es', 'meetupHubDetailsHide', 'Ocultar detalles'),
('he', 'meetupHubDetailsHide', 'להסתיר פרטים')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
