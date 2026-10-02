-- Seed admin profile edit UI translations (en/es/he). Safe to re-run.

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminStatusComplete', $$Completed$$),
  ('es', 'adminStatusComplete', $$Completado$$),
  ('he', 'adminStatusComplete', $$הושלם$$),

  ('en', 'adminChangeHistory', $$Change History$$),
  ('es', 'adminChangeHistory', $$Historial de cambios$$),
  ('he', 'adminChangeHistory', $$היסטוריית שינויים$$),

  ('en', 'adminOldValue', $$Old value$$),
  ('es', 'adminOldValue', $$Valor anterior$$),
  ('he', 'adminOldValue', $$ערך ישן$$),

  ('en', 'adminNewValue', $$New value$$),
  ('es', 'adminNewValue', $$Valor nuevo$$),
  ('he', 'adminNewValue', $$ערך חדש$$),

  ('en', 'adminProfileEditsNoMessage', $$No message.$$),
  ('es', 'adminProfileEditsNoMessage', $$Sin mensaje.$$),
  ('he', 'adminProfileEditsNoMessage', $$אין הודעה.$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
