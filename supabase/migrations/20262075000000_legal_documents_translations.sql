-- Migration: Translations for the in-app legal document viewer, chat
-- message load failure state, and the shared search + filter/sort bar
-- (Chats, Matches, Events).
--
-- This is the single complete source for these keys in all three shipped
-- locales (en, es, he). English rows are included so copy can be changed
-- server-side without a release. Values match
-- _defaultTranslations (lib/providers/locale_provider.dart) unless noted.
--
-- Corrections vs the first version of this file:
--   * es sortTopRated was Hebrew ('המדורגים ביותר') -> 'Mejor valorados'
--     (matches sortOptionTopRated es in add_match_score_translations.sql).
--   * es sortExpiringSoon was Hebrew ('עומדים לפוג') -> 'Termina pronto'
--     (matches sortOptionExpiringSoon es).
--   * he sortExpiringSoon was broken ('עומדות לפוגעת') -> 'מסתיים בקרוב'
--     (matches sortOptionExpiringSoon he; short neutral chip label).
--   * he matchesSearchHint used תחביב -> 'שם, תחום עניין או אירוע'
--     (app standard is תחום עניין, e.g. sharedInterestsCount he
--     'תחומי עניין משותפים').
--   * he sortSharedInterests used תחביבים -> 'תחומי עניין משותפים'
--     (matches sharedInterestsCount he, matchProfileSharedInterests he).
--   * he settingsLegalPrivacyDesc was missing -> added
--     'מה אנחנו אוספים וכמה זמן אנחנו שומרים את זה'.
--   * matchTypeFilterProximityBlurb must not claim live proximity:
--     en 'Near you now' -> 'Met nearby', es 'Cerca de ti ahora'
--     -> 'Se conocieron cerca', he 'קרובים אליך עכשיו' -> 'נפגשו בקרבה'
--     (past tense, matches 'How you met' / 'Cómo se conocieron' /
--     'איך נפגשו' and 'You were nearby each other').
--   * chatsSearchHint es/he were shortened vs en + vs 20262039000000:
--     es 'Nombre o mensaje' -> 'Buscar por nombre o mensaje',
--     he 'שם או הודעה' -> 'חיפוש לפי שם או הודעה'.
--   * es sortUnreadFirst 'Sin leer primero' -> 'No leídos primero'
--     (adjectival; matches 'Solo no leídos' in 20262052000000).
--
-- NOTE: if 20262075000000 already applied, Supabase will not re-run an
-- edited migration. Apply this file manually (psql / dashboard) or
-- squash via a follow-up migration.

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Chat message list failed to load.
  ('en', 'chatMessagesLoadFailed', 'We couldn''t load these messages.'),
  ('es', 'chatMessagesLoadFailed', 'No pudimos cargar estos mensajes.'),
  ('he', 'chatMessagesLoadFailed', 'לא הצלחנו לטעון את ההודעות.'),

  -- Legal document screen.
  ('en', 'legalDocumentUnavailable', 'This document could not be loaded.'),
  ('es', 'legalDocumentUnavailable', 'No se pudo cargar este documento.'),
  ('he', 'legalDocumentUnavailable', 'לא ניתן היה לטעון את המסמך.'),
  ('en', 'legalTryAgain', 'Try again'),
  ('es', 'legalTryAgain', 'Intentar de nuevo'),
  ('he', 'legalTryAgain', 'נסה שוב'),

  -- Legal screen titles and English-fallback notice.
  ('en', 'legalTitleTerms', 'Terms of Service'),
  ('es', 'legalTitleTerms', 'Términos del servicio'),
  ('he', 'legalTitleTerms', 'תנאי שימוש'),
  ('en', 'legalTitlePrivacy', 'Privacy Policy'),
  ('es', 'legalTitlePrivacy', 'Política de privacidad'),
  ('he', 'legalTitlePrivacy', 'מדיניות פרטיות'),
  ('en', 'legalEnglishFallbackNotice', 'This document is not yet available in your language, so it is shown in English.'),
  ('es', 'legalEnglishFallbackNotice', 'Este documento aún no está disponible en tu idioma, por lo que se muestra en inglés.'),
  ('he', 'legalEnglishFallbackNotice', 'מסמך זה אינו זמין עדיין בשפה שלך, ולכן הוא מוצג באנגלית.'),

  -- Settings rows for the legal documents.
  ('en', 'settingsLegalTerms', 'Terms of Service'),
  ('es', 'settingsLegalTerms', 'Términos del servicio'),
  ('he', 'settingsLegalTerms', 'תנאי שימוש'),
  ('en', 'settingsLegalTermsDesc', 'The rules for using MatchMe'),
  ('es', 'settingsLegalTermsDesc', 'Las reglas para usar MatchMe'),
  ('he', 'settingsLegalTermsDesc', 'הכללים לשימוש ב-MatchMe'),
  ('en', 'settingsLegalPrivacy', 'Privacy Policy'),
  ('es', 'settingsLegalPrivacy', 'Política de privacidad'),
  ('he', 'settingsLegalPrivacy', 'מדיניות פרטיות'),
  ('en', 'settingsLegalPrivacyDesc', 'What we collect, and how long we keep it'),
  ('es', 'settingsLegalPrivacyDesc', 'Qué recopilamos y durante cuánto tiempo lo conservamos'),
  ('he', 'settingsLegalPrivacyDesc', 'מה אנחנו אוספים וכמה זמן אנחנו שומרים את זה'),

  -- Search on Matches and Events, plus shared match-type filter.
  ('en', 'matchesSearchLabel', 'Search matches'),
  ('es', 'matchesSearchLabel', 'Buscar coincidencias'),
  ('he', 'matchesSearchLabel', 'חיפוש התאמות'),
  ('en', 'matchesSearchHint', 'Name, interest or event'),
  ('es', 'matchesSearchHint', 'Nombre, interés o evento'),
  ('he', 'matchesSearchHint', 'שם, תחום עניין או אירוע'),
  ('en', 'eventsSearchLabel', 'Search events'),
  ('es', 'eventsSearchLabel', 'Buscar eventos'),
  ('he', 'eventsSearchLabel', 'חיפוש אירועים'),
  ('en', 'eventsSearchHint', 'Event, venue or description'),
  ('es', 'eventsSearchHint', 'Evento, lugar o descripción'),
  ('he', 'eventsSearchHint', 'אירוע, מקום או תיאור'),
  ('en', 'eventsNoSearchResults', 'No events found'),
  ('es', 'eventsNoSearchResults', 'No se encontraron eventos'),
  ('he', 'eventsNoSearchResults', 'לא נמצאו אירועים'),
  ('en', 'eventsNoSearchResultsMessage', 'No event matches that search. Try a different word, or clear the search.'),
  ('es', 'eventsNoSearchResultsMessage', 'Ningún evento coincide con esa búsqueda. Prueba con otra palabra o borra la búsqueda.'),
  ('he', 'eventsNoSearchResultsMessage', 'אין אירוע שתואם לחיפוש. נסה מילה אחרת או נקה את החיפוש.'),
  ('en', 'matchTypeFilterProximity', 'Nearby'),
  ('es', 'matchTypeFilterProximity', 'Cerca'),
  ('he', 'matchTypeFilterProximity', 'קרובים'),
  ('en', 'matchTypeFilterEvent', 'Event'),
  ('es', 'matchTypeFilterEvent', 'Evento'),
  ('he', 'matchTypeFilterEvent', 'אירוע'),

  -- Shared search + filter bar (Chats, Matches, Events).
  ('en', 'matchTypeFilterLabel', 'How you met'),
  ('es', 'matchTypeFilterLabel', 'Cómo se conocieron'),
  ('he', 'matchTypeFilterLabel', 'איך נפגשו'),
  ('en', 'matchTypeFilterAllBlurb', 'Everyone'),
  ('es', 'matchTypeFilterAllBlurb', 'Todos'),
  ('he', 'matchTypeFilterAllBlurb', 'כולם'),
  ('en', 'matchTypeFilterProximityBlurb', 'Met nearby'),
  ('es', 'matchTypeFilterProximityBlurb', 'Se conocieron cerca'),
  ('he', 'matchTypeFilterProximityBlurb', 'נפגשו בקרבה'),
  ('en', 'matchTypeFilterEventBlurb', 'Same event'),
  ('es', 'matchTypeFilterEventBlurb', 'Mismo evento'),
  ('he', 'matchTypeFilterEventBlurb', 'אותו אירוע'),
  ('en', 'listFiltersTitle', 'Filters'),
  ('es', 'listFiltersTitle', 'Filtros'),
  ('he', 'listFiltersTitle', 'מסננים'),
  ('en', 'listFilterInterestSection', 'What they are looking for'),
  ('es', 'listFilterInterestSection', 'Qué buscan'),
  ('he', 'listFilterInterestSection', 'מה הם מחפשים'),
  ('en', 'listFilterOptionsSection', 'Options'),
  ('es', 'listFilterOptionsSection', 'Opciones'),
  ('he', 'listFilterOptionsSection', 'אפשרויות'),
  ('en', 'listFilterShowResults', 'Show {count} results'),
  ('es', 'listFilterShowResults', 'Mostrar {count} resultados'),
  ('he', 'listFilterShowResults', 'הצג {count} תוצאות'),
  ('en', 'listFilterResultCount', '{count} conversations'),
  ('es', 'listFilterResultCount', '{count} conversaciones'),
  ('he', 'listFilterResultCount', '{count} שיחות'),
  ('en', 'listFilterResultCountOf', '{shown} of {total} conversations'),
  ('es', 'listFilterResultCountOf', '{shown} de {total} conversaciones'),
  ('he', 'listFilterResultCountOf', '{shown} מתוך {total} שיחות'),
  ('en', 'chatsSearchHint', 'Search by name or message'),
  ('es', 'chatsSearchHint', 'Buscar por nombre o mensaje'),
  ('he', 'chatsSearchHint', 'חיפוש לפי שם או הודעה'),
  ('en', 'chatsSearchingMessages', 'Searching all messages on this device…'),
  ('es', 'chatsSearchingMessages', 'Buscando en todos los mensajes de este dispositivo…'),
  ('he', 'chatsSearchingMessages', 'מחפש בכל ההודעות במכשיר הזה…'),
  ('en', 'chatsSearchInTranslated', 'Matched in a translation'),
  ('es', 'chatsSearchInTranslated', 'Coincidencia en una traducción'),
  ('he', 'chatsSearchInTranslated', 'התאמה בתרגום'),

  -- Sort control (Matches) + shared sort section (Chats, Matches).
  ('en', 'sortNewest', 'Newest'),
  ('es', 'sortNewest', 'Más recientes'),
  ('he', 'sortNewest', 'החדשים ביותר'),
  ('en', 'sortSharedInterests', 'Shared interests'),
  ('es', 'sortSharedInterests', 'Intereses compartidos'),
  ('he', 'sortSharedInterests', 'תחומי עניין משותפים'),
  ('en', 'sortTopRated', 'Top rated'),
  ('es', 'sortTopRated', 'Mejor valorados'),
  ('he', 'sortTopRated', 'המדורגים הגבוהים ביותר'),
  ('en', 'sortExpiringSoon', 'Expiring soon'),
  ('es', 'sortExpiringSoon', 'Termina pronto'),
  ('he', 'sortExpiringSoon', 'מסתיים בקרוב'),
  ('en', 'listSortSection', 'Sort by'),
  ('es', 'listSortSection', 'Ordenar por'),
  ('he', 'listSortSection', 'מיון לפי'),
  ('en', 'sortUnreadFirst', 'Unread first'),
  ('es', 'sortUnreadFirst', 'No leídos primero'),
  ('he', 'sortUnreadFirst', 'לא נקראו תחילה'),
  ('en', 'sortNameAsc', 'Name A–Z'),
  ('es', 'sortNameAsc', 'Nombre A–Z'),
  ('he', 'sortNameAsc', 'שם א׳–ת׳')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
