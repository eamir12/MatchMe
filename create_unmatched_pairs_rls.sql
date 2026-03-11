-- RLS Policies for unmatched_pairs table
-- This table stores pairs of users who have unmatched each other

-- Enable RLS on the table
ALTER TABLE public.unmatched_pairs ENABLE ROW LEVEL SECURITY;

-- Policy: Users can view only their own unmatched pairs
-- (where they are either user1_id or user2_id)
CREATE POLICY unmatched_pairs_select_policy
ON public.unmatched_pairs
FOR SELECT
TO authenticated
USING (
    auth.uid() = user1_id OR auth.uid() = user2_id
);

-- Policy: Users can insert unmatched pairs only for themselves
-- (when they are one of the users in the pair)
CREATE POLICY unmatched_pairs_insert_policy
ON public.unmatched_pairs
FOR INSERT
TO authenticated
WITH CHECK (
    auth.uid() = user1_id OR auth.uid() = user2_id
);

-- Note: Updates and deletes are intentionally not allowed
-- Once a pair is marked as unmatched, it should remain as a permanent record
-- to prevent users from being re-matched

-- Grant necessary permissions
GRANT SELECT, INSERT ON public.unmatched_pairs TO authenticated;

-- Ensure the table owner can still manage the table
GRANT ALL ON public.unmatched_pairs TO postgres;
