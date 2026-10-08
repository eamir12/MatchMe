-- Migration: Import-block explainer sheet + false-positive feedback table
--
-- Companion to the second round of calendar-import privacy work:
--  * a "why can't I import this?" bottom sheet replaces the transient
--    snackbar, and
--  * a "This event is actually public" action logs the classifier decision
--    inputs (scrubbed title, reason, provider, locale) to
--    public.event_import_feedback so the local heuristics can be tuned.
--
-- Also adds en/he/es translations for the new sheet and manual-entry
-- dialog strings. English fallbacks already live in Dart
-- (locale_provider.dart _defaultTranslations).
--
-- Titles are scrubbed client-side (emails and phone numbers stripped)
-- before insert; RLS limits inserts to the authenticated owner's row.
BEGIN;

CREATE TABLE IF NOT EXISTS public.event_import_feedback (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  block_reason text NOT NULL,
  event_title text,
  provider text,
  app_locale text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.event_import_feedback ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "authenticated users can submit import feedback"
  ON public.event_import_feedback;

CREATE POLICY "authenticated users can submit import feedback"
  ON public.event_import_feedback
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

-- No read/update/delete policies on purpose: feedback rows are
-- write-only from the client; review them via the dashboard or a
-- service-role query.

GRANT INSERT ON public.event_import_feedback TO authenticated;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'importBlockSheetTitlePrivate', 'This event is marked private'),
  ('en', 'importBlockSheetBodyPrivate', 'Your calendar marks this event as private or “free”. MatchMe events are shared with your matches, so private calendar entries can’t be imported.'),
  ('en', 'importBlockSheetTitlePersonal', 'This looks like a personal event'),
  ('en', 'importBlockSheetBodyPersonal', '“{title}” looks like a personal appointment rather than a public event. MatchMe events are visible to your matches, so personal items can’t be imported.'),
  ('en', 'importBlockSheetTitleContext', 'Nothing public to share'),
  ('en', 'importBlockSheetBodyContext', 'This event has neither a public link nor a physical location, so there’s nothing here for other users to attend.'),
  ('en', 'importBlockSheetWhatImportableTitle', 'What can I import?'),
  ('en', 'importBlockSheetWhatImportableBody', 'Public events other users can join — concerts, meetups, exhibitions, public classes, parties — as long as they have a venue or a link.'),
  ('en', 'importBlockSheetFeedbackButton', 'This event is actually public'),
  ('en', 'importBlockSheetFeedbackThanks', 'Thanks — we’ll take a look at this decision.'),
  ('en', 'eventAddLooksPrivateTitle', 'This looks personal'),
  ('en', 'eventAddLooksPrivateBody', '“{title}” looks like a personal appointment rather than a public event. MatchMe events are visible to your matches — consider sharing only events others can join.'),
  ('en', 'eventAddLooksPrivateConfirmButton', 'Add anyway')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'importBlockSheetTitlePrivate', 'האירוע מסומן כפרטי'),
  ('he', 'importBlockSheetBodyPrivate', 'היומן שלך מסמן את האירוע הזה כפרטי או כפנוי. אירועים ב-MatchMe משותפים עם ההתאמות שלך, ולכן לא ניתן לייבא פריטים פרטיים מהיומן.'),
  ('he', 'importBlockSheetTitlePersonal', 'נראה שזהו אירוע אישי'),
  ('he', 'importBlockSheetBodyPersonal', '“{title}” נראה כמו פגישה אישית ולא כמו אירוע ציבורי. אירועים ב-MatchMe גלויים להתאמות שלך, ולכן לא ניתן לייבא פריטים אישיים.'),
  ('he', 'importBlockSheetTitleContext', 'אין כאן מה לשתף'),
  ('he', 'importBlockSheetBodyContext', 'לאירוע הזה אין לא קישור ציבורי ולא מקום פיזי, ולכן אין כאן משהו שמשתמשים אחרים יכולים להגיע אליו.'),
  ('he', 'importBlockSheetWhatImportableTitle', 'מה אפשר לייבא?'),
  ('he', 'importBlockSheetWhatImportableBody', 'אירועים ציבוריים שמשתמשים אחרים יכולים להצטרף אליהם — הופעות, מיטאפים, תערוכות, שיעורים פומביים, מסיבות — בתנאי שיש להם מקום או קישור.'),
  ('he', 'importBlockSheetFeedbackButton', 'האירוע הזה דווקא ציבורי'),
  ('he', 'importBlockSheetFeedbackThanks', 'תודה — נבחן את ההחלטה הזאת.'),
  ('he', 'eventAddLooksPrivateTitle', 'נראה שזה אישי'),
  ('he', 'eventAddLooksPrivateBody', '“{title}” נראה כמו פגישה אישית ולא כמו אירוע ציבורי. אירועים ב-MatchMe גלויים להתאמות שלך — מומלץ לשתף רק אירועים שאחרים יכולים להצטרף אליהם.'),
  ('he', 'eventAddLooksPrivateConfirmButton', 'להוסיף בכל זאת')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'importBlockSheetTitlePrivate', 'Este evento está marcado como privado'),
  ('es', 'importBlockSheetBodyPrivate', 'Tu calendario marca este evento como privado o «libre». Los eventos de MatchMe se comparten con tus conexiones, por lo que no se pueden importar entradas privadas del calendario.'),
  ('es', 'importBlockSheetTitlePersonal', 'Esto parece un evento personal'),
  ('es', 'importBlockSheetBodyPersonal', '“{title}” parece una cita personal en lugar de un evento público. Los eventos de MatchMe son visibles para tus conexiones, por lo que no se pueden importar elementos personales.'),
  ('es', 'importBlockSheetTitleContext', 'Nada público que compartir'),
  ('es', 'importBlockSheetBodyContext', 'Este evento no tiene ni un enlace público ni un lugar físico, así que no hay nada aquí al que otros usuarios puedan asistir.'),
  ('es', 'importBlockSheetWhatImportableTitle', '¿Qué puedo importar?'),
  ('es', 'importBlockSheetWhatImportableBody', 'Eventos públicos a los que otros usuarios pueden unirse — conciertos, meetups, exposiciones, clases públicas, fiestas — siempre que tengan un lugar o un enlace.'),
  ('es', 'importBlockSheetFeedbackButton', 'Este evento sí es público'),
  ('es', 'importBlockSheetFeedbackThanks', 'Gracias — revisaremos esta decisión.'),
  ('es', 'eventAddLooksPrivateTitle', 'Esto parece personal'),
  ('es', 'eventAddLooksPrivateBody', '“{title}” parece una cita personal en lugar de un evento público. Los eventos de MatchMe son visibles para tus conexiones — considera compartir solo eventos a los que otros puedan unirse.'),
  ('es', 'eventAddLooksPrivateConfirmButton', 'Añadir de todos modos')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
