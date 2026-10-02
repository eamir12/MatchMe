-- Migration: Backfill "Someone"/"מישהו"/"Alguien" placeholder titles in the
-- notification inbox (public.user_notifications).
--
-- Background:
--   While get_masked_sender_name was broken (parameter renamed to `sender_id`
--   by 20260710100000, caller still passing `p_sender_id`), every chat-message
--   push recorded in the persistent inbox fell back to the localized
--   "someone" placeholder as its title. The RPC is fixed by
--   20261002000000, but titles already stored in user_notifications are
--   baked in — this rewrites them using the same RPC going forward.
--
-- Scope:
--   - type = 'chat_message' only (the only type that used the placeholder
--     as its title)
--   - title exactly matching one of the placeholder strings from
--     push-message's _pushStrings table (en/he/es)
--   - rows whose data carries sender_id (all chat_message rows do)
--   - only when the RPC now resolves a real name; rows whose sender still
--     has no name are left as-is rather than becoming "Unknown User"

UPDATE public.user_notifications un
SET title = public.get_masked_sender_name((un.data ->> 'sender_id')::uuid)
WHERE un.type = 'chat_message'
  AND un.title IN ('Someone', 'מישהו', 'Alguien')
  AND un.data ->> 'sender_id' IS NOT NULL
  AND NULLIF(
    public.get_masked_sender_name((un.data ->> 'sender_id')::uuid),
    'Unknown User'
  ) IS NOT NULL;
