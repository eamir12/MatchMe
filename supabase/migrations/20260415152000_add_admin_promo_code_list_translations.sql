INSERT INTO public.translations (key, value, locale)
VALUES
  ('adminPromoCodesTabAllCodes', 'All Codes', 'en'),
  ('adminPromoCodesTabAllCodes', 'Todos los codigos', 'es'),
  ('adminPromoCodesTabAllCodes', 'כל הקודים', 'he'),

  ('adminPromoCodesSearchLabel', 'Search promo codes', 'en'),
  ('adminPromoCodesSearchLabel', 'Buscar codigos promocionales', 'es'),
  ('adminPromoCodesSearchLabel', 'חיפוש קודי קידום', 'he'),

  ('adminPromoCodesSearchHint', 'Search by code, description, campaign, or tier', 'en'),
  ('adminPromoCodesSearchHint', 'Buscar por codigo, descripcion, campana o nivel', 'es'),
  ('adminPromoCodesSearchHint', 'חיפוש לפי קוד, תיאור, קמפיין או דרגה', 'he'),

  ('adminPromoCodesClearSearch', 'Clear search', 'en'),
  ('adminPromoCodesClearSearch', 'Borrar busqueda', 'es'),
  ('adminPromoCodesClearSearch', 'ניקוי חיפוש', 'he'),

  ('adminPromoCodesFilterAll', 'All', 'en'),
  ('adminPromoCodesFilterAll', 'Todos', 'es'),
  ('adminPromoCodesFilterAll', 'הכל', 'he'),

  ('adminPromoCodesFilterEnabled', 'Enabled', 'en'),
  ('adminPromoCodesFilterEnabled', 'Habilitados', 'es'),
  ('adminPromoCodesFilterEnabled', 'מופעלים', 'he'),

  ('adminPromoCodesFilterDisabled', 'Disabled', 'en'),
  ('adminPromoCodesFilterDisabled', 'Deshabilitados', 'es'),
  ('adminPromoCodesFilterDisabled', 'מושבתים', 'he'),

  ('adminPromoCodesFilterExpired', 'Expired', 'en'),
  ('adminPromoCodesFilterExpired', 'Vencidos', 'es'),
  ('adminPromoCodesFilterExpired', 'פגי תוקף', 'he'),

  ('adminPromoCodesStatusEnabled', 'Enabled', 'en'),
  ('adminPromoCodesStatusEnabled', 'Habilitado', 'es'),
  ('adminPromoCodesStatusEnabled', 'מופעל', 'he'),

  ('adminPromoCodesStatusDisabled', 'Disabled', 'en'),
  ('adminPromoCodesStatusDisabled', 'Deshabilitado', 'es'),
  ('adminPromoCodesStatusDisabled', 'מושבת', 'he'),

  ('adminPromoCodesStatusExpired', 'Expired', 'en'),
  ('adminPromoCodesStatusExpired', 'Vencido', 'es'),
  ('adminPromoCodesStatusExpired', 'פג תוקף', 'he'),

  ('adminPromoCodesEmpty', 'No promo codes yet', 'en'),
  ('adminPromoCodesEmpty', 'Todavia no hay codigos promocionales', 'es'),
  ('adminPromoCodesEmpty', 'עדיין אין קודי קידום', 'he'),

  ('adminPromoCodesEmptyFiltered', 'No promo codes match the current search or filters', 'en'),
  ('adminPromoCodesEmptyFiltered', 'Ningun codigo promocional coincide con la busqueda o los filtros actuales', 'es'),
  ('adminPromoCodesEmptyFiltered', 'אין קודי קידום שתואמים לחיפוש או למסננים הנוכחיים', 'he'),

  ('adminPromoCodesShowingCount', 'Showing {shown} of {total} codes', 'en'),
  ('adminPromoCodesShowingCount', 'Mostrando {shown} de {total} codigos', 'es'),
  ('adminPromoCodesShowingCount', 'מציג {shown} מתוך {total} קודים', 'he')
ON CONFLICT (key, locale) DO UPDATE
SET value = EXCLUDED.value;
