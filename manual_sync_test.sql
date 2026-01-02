-- Force a manual sync of matches for the current user
-- Replace 'your_user_id_here' with your actual user ID

SELECT sync_matches('your_user_id_here');

-- Then check if matches appear in local view
SELECT * FROM matches WHERE user1_id = 'your_user_id_here' OR user2_id = 'your_user_id_here' ORDER BY created_at DESC LIMIT 5;