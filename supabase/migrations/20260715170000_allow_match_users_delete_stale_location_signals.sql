-- Allow both match participants to delete stale location share signals
-- Previously only the sharer could delete their own signal.
-- If the sharer's app crashes or the delete fails, the stale signal
-- would cause the receiver to see "Live Location Active" indefinitely.

DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'Users can delete own signals' AND tablename = 'location_share_signals'
  ) THEN
    DROP POLICY "Users can delete own signals" ON location_share_signals;
  END IF;
END $$;

CREATE POLICY "Users can delete match signals"
  ON location_share_signals
  FOR DELETE
  USING (
    match_id IN (
      SELECT id::text FROM matches
      WHERE user1_id = auth.uid() OR user2_id = auth.uid()
    )
  );
