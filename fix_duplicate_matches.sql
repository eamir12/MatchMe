-- Fix duplicate matches by ensuring each user pair only appears once
-- regardless of order (user1_id, user2_id) vs (user2_id, user1_id)

-- First, drop the existing constraint
ALTER TABLE matches DROP CONSTRAINT IF EXISTS matches_user_a_id_user_b_id_key;

-- Create a new unique index that handles both orders
-- We'll use a generated column or a check constraint
-- For now, let's clean up existing duplicates and add a better constraint

-- Delete duplicate matches (keep the one with the smaller user ID first)
DELETE FROM matches m1
WHERE EXISTS (
    SELECT 1 FROM matches m2
    WHERE (
        (m1.user1_id = m2.user2_id AND m1.user2_id = m2.user1_id) OR
        (m1.user1_id = m2.user1_id AND m1.user2_id = m2.user2_id)
    )
    AND m1.id > m2.id  -- Keep the one with smaller ID
    AND m1.user1_id > m1.user2_id  -- Only delete if user1_id > user2_id (keep consistent ordering)
);

-- Add a unique constraint that ensures user1_id < user2_id
-- First, reorder any remaining matches where user1_id > user2_id
UPDATE matches
SET user1_id = user2_id, user2_id = user1_id
WHERE user1_id > user2_id;

-- Now add the unique constraint
ALTER TABLE matches ADD CONSTRAINT matches_unique_pair UNIQUE (user1_id, user2_id);

-- Also ensure user1_id < user2_id with a check constraint
ALTER TABLE matches ADD CONSTRAINT matches_ordered_users CHECK (user1_id < user2_id);
