INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'matchesClearFilters', 'Clear filters'),
  ('en', 'matchesNoIntentResults', 'No matches for this connection type'),
  ('en', 'matchesNoIntentResultsMessage', 'Try another connection type or clear the filter to see all matches.'),
  ('es', 'matchesClearFilters', 'Borrar filtros'),
  ('es', 'matchesNoIntentResults', 'No hay coincidencias para este tipo de conexión'),
  ('es', 'matchesNoIntentResultsMessage', 'Prueba otro tipo de conexión o borra el filtro para ver todas las coincidencias.'),
  ('he', 'matchesClearFilters', 'ניקוי מסננים'),
  ('he', 'matchesNoIntentResults', 'אין התאמות לסוג חיבור זה'),
  ('he', 'matchesNoIntentResultsMessage', 'נסו סוג חיבור אחר או נקו את המסנן כדי לראות את כל ההתאמות.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
