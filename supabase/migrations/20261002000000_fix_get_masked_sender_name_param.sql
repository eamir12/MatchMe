-- Migration: Normalize get_masked_sender_name's parameter name back to p_sender_id
--
-- Background:
--   The edge function `push-message` calls this RPC with the named argument
--   `p_sender_id` (the name from the original 20260605000000 migration).
--   Migration 20260710100000 (STEP 14) rewrote the function for the new schema
--   but renamed the parameter to `sender_id`. PostgREST resolves RPCs by named
--   argument, so the call started failing with:
--     "Could not find the function public.get_masked_sender_name(p_sender_id)
--      in the schema cache"
--   and chat push notifications fell back to "Someone" / "מישהו".
--
--   Postgres function identity is (schema, name, arg types); the parameter
--   name is not part of the signature, but CREATE OR REPLACE still refuses to
--   rename an existing parameter (error 42P13), so we DROP and recreate.
--
-- Body matches the new-schema version (users.name is the single source of
-- truth); mask_full_name returns 'Unknown User' when the name is null/empty.

DROP FUNCTION IF EXISTS public.get_masked_sender_name(uuid);

CREATE FUNCTION public.get_masked_sender_name(p_sender_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    full_name text;
BEGIN
    IF p_sender_id IS NULL THEN
        RETURN '';
    END IF;

    SELECT u.name INTO full_name FROM users u WHERE u.id = p_sender_id;
    RETURN public.mask_full_name(full_name);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_masked_sender_name(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_masked_sender_name(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_masked_sender_name(uuid) TO service_role;
