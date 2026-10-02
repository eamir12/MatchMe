BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminSponsoredAdsLocalesHelp', 'Keep English as the base copy, then add only the extra languages this ad needs.'),
  ('es', 'adminSponsoredAdsLocalesHelp', 'Manten el ingles como texto base y luego agrega solo los idiomas extra que necesite este anuncio.'),
  ('he', 'adminSponsoredAdsLocalesHelp', 'השאר את האנגלית כטקסט הבסיס, ואז הוסף רק את השפות הנוספות שהמודעה צריכה.'),

  ('en', 'adminSponsoredAdsLocalesSelected', 'Selected languages'),
  ('es', 'adminSponsoredAdsLocalesSelected', 'Idiomas seleccionados'),
  ('he', 'adminSponsoredAdsLocalesSelected', 'שפות נבחרות'),

  ('en', 'adminSponsoredAdsLocalesCompleted', 'Completed'),
  ('es', 'adminSponsoredAdsLocalesCompleted', 'Completado'),
  ('he', 'adminSponsoredAdsLocalesCompleted', 'הושלם'),

  ('en', 'adminSponsoredAdsLocalesMissing', 'Needs attention'),
  ('es', 'adminSponsoredAdsLocalesMissing', 'Necesita atencion'),
  ('he', 'adminSponsoredAdsLocalesMissing', 'דורש תשומת לב'),

  ('en', 'adminSponsoredAdsLocalesAdd', 'Add language'),
  ('es', 'adminSponsoredAdsLocalesAdd', 'Agregar idioma'),
  ('he', 'adminSponsoredAdsLocalesAdd', 'הוסף שפה'),

  ('en', 'adminSponsoredAdsLocalesSearchHint', 'Search languages'),
  ('es', 'adminSponsoredAdsLocalesSearchHint', 'Buscar idiomas'),
  ('he', 'adminSponsoredAdsLocalesSearchHint', 'חפש שפות'),

  ('en', 'adminSponsoredAdsLocalesEmptyState', 'No more languages match your search.'),
  ('es', 'adminSponsoredAdsLocalesEmptyState', 'No hay mas idiomas que coincidan con tu busqueda.'),
  ('he', 'adminSponsoredAdsLocalesEmptyState', 'אין שפות נוספות שתואמות לחיפוש שלך.'),

  ('en', 'adminSponsoredAdsLocalesCode', 'Code'),
  ('es', 'adminSponsoredAdsLocalesCode', 'Codigo'),
  ('he', 'adminSponsoredAdsLocalesCode', 'קוד'),

  ('en', 'adminSponsoredAdsLocalePrimary', 'Primary'),
  ('es', 'adminSponsoredAdsLocalePrimary', 'Principal'),
  ('he', 'adminSponsoredAdsLocalePrimary', 'ראשי'),

  ('en', 'adminSponsoredAdsLocaleRemove', 'Remove language'),
  ('es', 'adminSponsoredAdsLocaleRemove', 'Quitar idioma'),
  ('he', 'adminSponsoredAdsLocaleRemove', 'הסר שפה'),

  ('en', 'adminSponsoredAdsLocalesSectionHint', 'Only this language block opens while you edit, so the form stays manageable even with many locales.'),
  ('es', 'adminSponsoredAdsLocalesSectionHint', 'Solo este bloque de idioma se abre mientras editas, para que el formulario siga siendo manejable incluso con muchos idiomas.'),
  ('he', 'adminSponsoredAdsLocalesSectionHint', 'רק בלוק השפה הזה נפתח בזמן העריכה, כדי שהטופס יישאר נוח גם עם הרבה שפות.'),

  ('en', 'adminSponsoredAdsLocaleCopyEnglish', 'Copy English'),
  ('es', 'adminSponsoredAdsLocaleCopyEnglish', 'Copiar ingles'),
  ('he', 'adminSponsoredAdsLocaleCopyEnglish', 'העתק מאנגלית'),

  ('en', 'adminSponsoredAdsLocaleClear', 'Clear'),
  ('es', 'adminSponsoredAdsLocaleClear', 'Limpiar'),
  ('he', 'adminSponsoredAdsLocaleClear', 'נקה'),

  ('en', 'adminSponsoredAdsLocaleFieldHeadline', 'Headline'),
  ('es', 'adminSponsoredAdsLocaleFieldHeadline', 'Titular'),
  ('he', 'adminSponsoredAdsLocaleFieldHeadline', 'כותרת'),

  ('en', 'adminSponsoredAdsLocaleFieldBody', 'Body'),
  ('es', 'adminSponsoredAdsLocaleFieldBody', 'Texto'),
  ('he', 'adminSponsoredAdsLocaleFieldBody', 'תוכן'),

  ('en', 'adminSponsoredAdsLocaleFieldCta', 'CTA'),
  ('es', 'adminSponsoredAdsLocaleFieldCta', 'CTA'),
  ('he', 'adminSponsoredAdsLocaleFieldCta', 'CTA'),

  ('en', 'adminSponsoredAdsLocaleFieldSponsor', 'Sponsor name'),
  ('es', 'adminSponsoredAdsLocaleFieldSponsor', 'Nombre del patrocinador'),
  ('he', 'adminSponsoredAdsLocaleFieldSponsor', 'שם המפרסם'),

  ('en', 'adminSponsoredAdsLocaleStatusComplete', 'Complete'),
  ('es', 'adminSponsoredAdsLocaleStatusComplete', 'Completo'),
  ('he', 'adminSponsoredAdsLocaleStatusComplete', 'הושלם'),

  ('en', 'adminSponsoredAdsLocaleStatusMissing', 'Missing fields'),
  ('es', 'adminSponsoredAdsLocaleStatusMissing', 'Faltan campos'),
  ('he', 'adminSponsoredAdsLocaleStatusMissing', 'חסרים שדות')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
