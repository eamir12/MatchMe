-- Admin Broadcast System - Core Schema
-- This creates the minimal tables needed for admin message broadcasting

-- Main broadcast messages table
CREATE TABLE IF NOT EXISTS admin_broadcasts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    message_type TEXT DEFAULT 'info' CHECK (message_type IN ('info', 'warning', 'promotion', 'update')),
    
    -- URL support for clickable links
    action_url TEXT,
    action_url_text TEXT DEFAULT 'Learn More',
    
    -- Scheduling
    scheduled_at TIMESTAMPTZ,
    sent_at TIMESTAMPTZ,
    status TEXT DEFAULT 'draft' CHECK (status IN ('draft', 'scheduled', 'sending', 'sent', 'failed')),
    
    -- Filtering criteria (JSON for flexibility)
    filter_criteria JSONB DEFAULT '{}',
    
    -- Target counts for analytics
    target_user_count INTEGER DEFAULT 0,
    actual_sent_count INTEGER DEFAULT 0,
    
    -- Admin tracking
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Delivery tracking table
CREATE TABLE IF NOT EXISTS admin_broadcast_deliveries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    broadcast_id UUID REFERENCES admin_broadcasts(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    fcm_token TEXT,
    delivery_status TEXT DEFAULT 'pending' CHECK (delivery_status IN ('pending', 'sent', 'delivered', 'failed')),
    delivered_at TIMESTAMPTZ,
    failure_reason TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_admin_broadcasts_status ON admin_broadcasts(status);
CREATE INDEX IF NOT EXISTS idx_admin_broadcasts_scheduled ON admin_broadcasts(scheduled_at) WHERE status = 'scheduled';
CREATE INDEX IF NOT EXISTS idx_admin_broadcast_deliveries_broadcast ON admin_broadcast_deliveries(broadcast_id);
CREATE INDEX IF NOT EXISTS idx_admin_broadcast_deliveries_user ON admin_broadcast_deliveries(user_id);

-- Enable RLS
ALTER TABLE admin_broadcasts ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_broadcast_deliveries ENABLE ROW LEVEL SECURITY;

-- Basic RLS policies (can be enhanced later)
CREATE POLICY "Admins can manage broadcasts" ON admin_broadcasts
  FOR ALL USING (auth.uid() IS NOT NULL);

CREATE POLICY "Users can view own deliveries" ON admin_broadcast_deliveries
  FOR SELECT USING (user_id = auth.uid());

-- Trigger to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_admin_broadcasts_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_admin_broadcasts_updated_at
    BEFORE UPDATE ON admin_broadcasts
    FOR EACH ROW
    EXECUTE FUNCTION update_admin_broadcasts_updated_at();