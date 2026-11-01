-- In-person meet-up: switch exterior landmark suggestions to Google Places.
--
-- The client now asks the `place-suggestions` edge function first (which holds
-- the Google key as a project secret) and falls back to the keyless Overpass /
-- vector-tile path only when that function does not answer. The provider is a
-- config row, not a build-time constant, so Google can be turned off from the
-- admin app within the 5-minute app_config cache window if billing or a terms
-- question needs it stopped — without shipping a client release.
--
-- Rollback: set meetup.places_provider to anything other than 'google'.

-- ---------------------------------------------------------------------------
-- 1. Provider switch
-- ---------------------------------------------------------------------------

INSERT INTO public.app_config (
  config_key, config_value, config_type, category, description,
  is_user_configurable
) VALUES
('meetup.places_provider', to_jsonb('google'::text), 'string', 'meetup',
 'Exterior landmark suggestion provider. ''google'' calls the place-suggestions edge function (Google Places API, New); any other value uses the keyless Overpass mirrors with the vector-tile fallback. Takes effect within the app_config cache window (~5 minutes).', false)
ON CONFLICT (config_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Per-user lookup quota
--
-- The Google lookup bills per call, so it shares the ai_rate_limit mechanism
-- (its own task name) even though no AI service is involved.
-- ---------------------------------------------------------------------------

INSERT INTO public.app_config (
  config_key, config_value, config_type, category, description,
  is_user_configurable
) VALUES
('ai.rate_limit.place_suggestions.hourly', to_jsonb(60), 'number', 'ai',
 'Maximum landmark suggestion lookups per user per hour (Google Places path)', false),
('ai.rate_limit.place_suggestions.daily', to_jsonb(300), 'number', 'ai',
 'Maximum landmark suggestion lookups per user per day (Google Places path)', false)
ON CONFLICT (config_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. Attribution
--
-- Places content must carry Google Maps attribution wherever it is shown. The
-- meet-up suggestion list renders no map, so the text form is used, and it is
-- shown only when Google actually answered — the OSM path keeps its own
-- "© OpenStreetMap contributors" line.
-- ---------------------------------------------------------------------------

INSERT INTO public.translations (locale, key, value) VALUES
('en', 'meetupGoogleAttribution', 'Google Maps'),
('es', 'meetupGoogleAttribution', 'Google Maps'),
('he', 'meetupGoogleAttribution', 'Google Maps')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;