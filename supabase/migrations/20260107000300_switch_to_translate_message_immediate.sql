-- Migration: Change webhook to call translate-message-immediate function
-- Purpose: Use the existing working translation function instead of on-message-insert

-- Note: This is documentation of the webhook setup
-- The webhook should be configured to call the translate-message-immediate function
-- with the message ID and match ID from the chat_messages table INSERT event

-- Current webhook configuration should be:
-- Table: chat_messages
-- Event: INSERT
-- Function: translate-message-immediate
-- Payload: Should pass message_id and match_id to the function
