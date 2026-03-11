-- DEPRECATED: This migration approach was incorrect
-- A message existing in the database does NOT mean the device received it
-- The device must explicitly call mark_message_delivered() via the app
-- This migration is kept for reference but should NOT be deployed

-- The correct approach:
-- 1. App real-time handler calls mark_message_delivered() when event arrives
-- 2. App sync handler calls mark_message_delivered() when syncing messages
-- 3. This ensures 2 grey checkmarks only appear after device actually receives the message
