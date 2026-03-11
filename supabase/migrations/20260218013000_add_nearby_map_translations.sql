-- Add translation keys for Nearby map screen UI

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'mapLegendYou', 'You'),
  ('en', 'mapLegendOnlineUsersApprox', 'Online users (approx)'),
  ('en', 'mapShowingApproxUsers', 'Showing ~{count} users'),
  ('en', 'mapApproxUsersHere', 'Approx users here: {count}'),

  ('es', 'mapLegendYou', 'Tú'),
  ('es', 'mapLegendOnlineUsersApprox', 'Usuarios en línea (aprox.)'),
  ('es', 'mapShowingApproxUsers', 'Mostrando ~{count} usuarios'),
  ('es', 'mapApproxUsersHere', 'Usuarios aprox. aquí: {count}'),

  ('he', 'mapLegendYou', 'את/ה'),
  ('he', 'mapLegendOnlineUsersApprox', 'משתמשים אונליין (בערך)'),
  ('he', 'mapShowingApproxUsers', 'מציג/ה בערך {count} משתמשים'),
  ('he', 'mapApproxUsersHere', 'בערך משתמשים כאן: {count}')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

