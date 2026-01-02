-- Rename columns in matches table from user_a_id/user_b_id to user1_id/user2_id (if they exist)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'matches' AND column_name = 'user_a_id') THEN
        ALTER TABLE matches RENAME COLUMN user_a_id TO user1_id;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'matches' AND column_name = 'user_b_id') THEN
        ALTER TABLE matches RENAME COLUMN user_b_id TO user2_id;
    END IF;
END $$;