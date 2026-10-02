-- Add RLS UPDATE policy so the sharer can update expires_at on their own signals.
-- Location coordinates are NEVER stored — they flow through the encrypted broadcast
-- channel only. Row existence = sharing active; row deleted = sharing stopped.

-- 1. RLS policy: allow the sharer to UPDATE their own signal (for expires_at changes)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'Users can update own match signals' AND tablename = 'location_share_signals'
  ) THEN
    CREATE POLICY "Users can update own match signals"
      ON location_share_signals
      FOR UPDATE
      USING (
        sharer_id = auth.uid()
        AND match_id IN (
          SELECT id::text FROM matches
          WHERE user1_id = auth.uid() OR user2_id = auth.uid()
        )
      )
      WITH CHECK (
        sharer_id = auth.uid()
        AND match_id IN (
          SELECT id::text FROM matches
          WHERE user1_id = auth.uid() OR user2_id = auth.uid()
        )
      );
  END IF;
END $$;

-- 2. Index for faster lookups by sharer_id
CREATE INDEX IF NOT EXISTS idx_location_share_signals_sharer_id
  ON location_share_signals(sharer_id);
