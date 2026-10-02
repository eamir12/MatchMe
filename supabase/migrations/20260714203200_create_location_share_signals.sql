-- Lightweight signaling table for live location sharing
-- Stores only match_id + sharer_id (NO location data)
-- Used to notify User B that User A has started sharing

CREATE TABLE IF NOT EXISTS location_share_signals (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  match_id TEXT NOT NULL,
  sharer_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL
);

-- Index for fast lookup by match_id
CREATE INDEX IF NOT EXISTS idx_location_share_signals_match_id
  ON location_share_signals(match_id);

-- Index for cleanup of expired signals
CREATE INDEX IF NOT EXISTS idx_location_share_signals_expires_at
  ON location_share_signals(expires_at);

-- RLS: only authenticated users can read/write
ALTER TABLE location_share_signals ENABLE ROW LEVEL SECURITY;

-- Users can read signals for matches they are part of
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'Users can read own match signals' AND tablename = 'location_share_signals'
  ) THEN
    CREATE POLICY "Users can read own match signals"
      ON location_share_signals
      FOR SELECT
      USING (
        match_id IN (
          SELECT id::text FROM matches
          WHERE user1_id = auth.uid() OR user2_id = auth.uid()
        )
      );
  END IF;
END $$;

-- Users can insert signals for matches they are part of
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'Users can insert own match signals' AND tablename = 'location_share_signals'
  ) THEN
    CREATE POLICY "Users can insert own match signals"
      ON location_share_signals
      FOR INSERT
      WITH CHECK (
        sharer_id = auth.uid()
        AND match_id IN (
          SELECT id::text FROM matches
          WHERE user1_id = auth.uid() OR user2_id = auth.uid()
        )
      );
  END IF;
END $$;

-- Users can delete their own signals
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'Users can delete own signals' AND tablename = 'location_share_signals'
  ) THEN
    CREATE POLICY "Users can delete own signals"
      ON location_share_signals
      FOR DELETE
      USING (sharer_id = auth.uid());
  END IF;
END $$;

-- Function to clean up expired signals (run via cron or app)
CREATE OR REPLACE FUNCTION cleanup_expired_location_share_signals()
RETURNS void AS $$
BEGIN
  DELETE FROM location_share_signals WHERE expires_at < NOW();
END;
$$ LANGUAGE plpgsql;

-- Enable Realtime so Postgres Changes subscriptions can detect new signals
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'location_share_signals'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.location_share_signals;
  END IF;
END $$;
