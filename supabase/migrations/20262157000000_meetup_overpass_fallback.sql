-- Follow-up for environments where 20262156000000 was already applied.
-- The original Overpass mirrors were intermittently unreachable, which made
-- landmark suggestions wait for the client timeout. Keep the global-data
-- mirrors current; regional instances must not be listed because they return
-- no data outside their extract.

BEGIN;

INSERT INTO public.app_config (
  config_key, config_value, config_type, category, description,
  is_user_configurable
) VALUES (
  'meetup.overpass_endpoints',
  to_jsonb('https://overpass-api.de/api/interpreter,https://overpass.kumi.systems/api/interpreter,https://overpass.private.coffee/api/interpreter'::text),
  'string', 'meetup',
  'Comma-separated Overpass endpoints used for exterior landmark suggestions',
  false
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  updated_at = now();

INSERT INTO public.translations (locale, key, value) VALUES
('en','meetupLandmarkLookupFailed','We could not look up nearby places right now. Try again in a moment.'),
('es','meetupLandmarkLookupFailed','No pudimos buscar lugares cercanos ahora mismo. Inténtalo de nuevo en un momento.'),
('he','meetupLandmarkLookupFailed','לא הצלחנו לאתר מקומות בקרבת מקום כרגע. נסו שוב בעוד רגע.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
