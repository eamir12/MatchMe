-- Add in-chat (find in conversation) search translations
-- Languages: en (English), es (Spanish), he (Hebrew)

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'chatJumpToLatest', 'Back to latest messages'),
  ('es', 'chatJumpToLatest', 'Volver a los mensajes recientes'),
  ('he', 'chatJumpToLatest', 'חזרה להודעות האחרונות'),

  ('en', 'chatSearchHint', 'Search in conversation'),
  ('es', 'chatSearchHint', 'Buscar en la conversación'),
  ('he', 'chatSearchHint', 'חיפוש בשיחה'),

  ('en', 'chatSearchTooltip', 'Search in conversation'),
  ('es', 'chatSearchTooltip', 'Buscar en la conversación'),
  ('he', 'chatSearchTooltip', 'חיפוש בשיחה'),

  ('en', 'chatSearchClose', 'Close search'),
  ('es', 'chatSearchClose', 'Cerrar búsqueda'),
  ('he', 'chatSearchClose', 'סגירת החיפוש'),

  ('en', 'chatSearchNoResults', 'No messages found'),
  ('es', 'chatSearchNoResults', 'No se encontraron mensajes'),
  ('he', 'chatSearchNoResults', 'לא נמצאו הודעות'),

  ('en', 'chatSearchPrevious', 'Previous result'),
  ('es', 'chatSearchPrevious', 'Resultado anterior'),
  ('he', 'chatSearchPrevious', 'תוצאה קודמת'),

  ('en', 'chatSearchNext', 'Next result'),
  ('es', 'chatSearchNext', 'Siguiente resultado'),
  ('he', 'chatSearchNext', 'תוצאה הבאה'),

  ('en', 'chatSearchResultCount', '{current} of {total}'),
  ('es', 'chatSearchResultCount', '{current} de {total}'),
  ('he', 'chatSearchResultCount', '{current} מתוך {total}'),

  ('en', 'chatSearchMatchedInTranslation', 'Matched in translation'),
  ('es', 'chatSearchMatchedInTranslation', 'Coincidencia en la traducción'),
  ('he', 'chatSearchMatchedInTranslation', 'נמצא בתרגום')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
