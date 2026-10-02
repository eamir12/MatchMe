-- Cleanup: notes are no longer needed in UI, remove their translations
BEGIN;
DELETE FROM public.translations WHERE key IN ('matchInspectorPersonalInterestsNote', 'matchInspectorBusinessInterestsNote');
COMMIT;
