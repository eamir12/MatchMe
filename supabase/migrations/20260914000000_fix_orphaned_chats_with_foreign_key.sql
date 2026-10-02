-- Migration: Add foreign key constraint to chats table and cleanup orphaned entries
-- Purpose: Prevent orphaned chat rows when matches are deleted, and ensure data consistency

BEGIN;

-- 1) Clean up existing orphaned chats (where match_id doesn't exist in matches table)
DELETE FROM public.chats c
WHERE NOT EXISTS (
  SELECT 1 FROM public.matches m WHERE m.id = c.match_id
);

-- 2) Add foreign key constraint with ON DELETE CASCADE
-- This ensures that if a match is deleted, all associated chat rows are automatically removed
ALTER TABLE public.chats
ADD CONSTRAINT fk_chats_match_id
FOREIGN KEY (match_id) REFERENCES public.matches(id) ON DELETE CASCADE;

-- 3) Add a trigger to also verify user_id is still valid
-- (Though users should rarely be deleted, this adds extra safety)
CREATE OR REPLACE FUNCTION public.validate_chats_on_delete()
RETURNS TRIGGER AS $$
BEGIN
  -- If a user is ever soft-deleted or removed, clean up their chats
  -- (This is a safety measure; typically users are not hard-deleted)
  DELETE FROM public.chats WHERE user_id = OLD.id;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- Note: Do NOT attach this trigger to users table unless users are hard-deleted in your app.
-- Soft-delete patterns (using a deleted_at column) should not trigger this.
-- If implemented, users DELETE would clean up all their chats:
-- CREATE TRIGGER trg_validate_chats_on_user_delete
-- AFTER DELETE ON public.users
-- FOR EACH ROW EXECUTE FUNCTION public.validate_chats_on_delete();

COMMIT;
