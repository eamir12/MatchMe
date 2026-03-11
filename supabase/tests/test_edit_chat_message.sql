-- Test: verify that the canonical RPC `edit_chat_message` exists and has the expected signature
-- Run this against a test/staging database only.

BEGIN;

-- Fail the test if the function is not present
DO $$
DECLARE
  fcount integer;
  argtext text;
BEGIN
  SELECT count(*) INTO fcount FROM pg_proc WHERE proname = 'edit_chat_message';
  IF fcount = 0 THEN
    RAISE EXCEPTION 'TEST FAILED: edit_chat_message function not found in schema';
  END IF;

  SELECT pg_get_function_arguments(p.oid) INTO argtext
    FROM pg_proc p
   WHERE p.proname = 'edit_chat_message'
   LIMIT 1;

  IF argtext IS NULL OR argtext NOT LIKE '%p_message_id uuid%' OR argtext NOT LIKE '%p_new_content text%' THEN
    RAISE EXCEPTION 'TEST FAILED: edit_chat_message signature mismatch: %', argtext;
  END IF;
END;
$$;

-- Optional: a note for maintainers about exercising the function in integration tests where
-- the test harness can simulate appropriate jwt.claims/auth.uid(). This quick test focuses on
-- presence and signature which is sufficient to detect missing/incorrect deployments.

COMMIT;
