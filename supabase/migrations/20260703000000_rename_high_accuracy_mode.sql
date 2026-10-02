-- supabase/migrations/20260703000000_rename_high_accuracy_mode.sql
-- Migration: Rename high_accuracy_mode to background_matching_mode
-- Purpose: The feature was renamed from "High Accuracy Mode" to "Background Matching Mode"
--          to better reflect what it does: keep matching in the background after closing the app.

BEGIN;

DROP INDEX IF EXISTS public.idx_users_high_accuracy_mode;
ALTER TABLE IF EXISTS public.users RENAME COLUMN high_accuracy_mode TO background_matching_mode;
CREATE INDEX IF NOT EXISTS idx_users_background_matching_mode ON public.users (background_matching_mode);

COMMIT;
