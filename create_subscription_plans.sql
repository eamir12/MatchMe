-- Create subscription_plans table
CREATE TABLE IF NOT EXISTS public.subscription_plans (
    id TEXT PRIMARY KEY,
    tier_id TEXT NOT NULL REFERENCES public.subscription_tiers(id) ON DELETE CASCADE,
    duration TEXT NOT NULL, -- 'day', 'week', 'month', 'year'
    price_display TEXT NOT NULL, -- e.g., '$19.99'
    savings_text TEXT, -- e.g., 'Save 50%'
    revenue_cat_package_identifier TEXT, -- Optional, for actual purchase
    sort_order INTEGER DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable RLS
ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;

-- Create policy for public read access
CREATE POLICY "Allow public read access to subscription_plans"
    ON public.subscription_plans
    FOR SELECT
    USING (true);

-- Insert Plans
INSERT INTO public.subscription_plans (id, tier_id, duration, price_display, savings_text, sort_order)
VALUES
    -- PLUS Plans
    ('plus_daily', 'plus', 'day', '$1.99', NULL, 10),
    ('plus_weekly', 'plus', 'week', '$7.99', 'paywallSavePercent:40', 20),
    ('plus_monthly', 'plus', 'month', '$19.99', 'paywallSavePercent:70', 30),
    ('plus_annual', 'plus', 'year', '$99.99', 'paywallSavePercent:85', 40),

    -- GOLD Plans
    ('gold_daily', 'gold', 'day', '$2.99', NULL, 10),
    ('gold_weekly', 'gold', 'week', '$12.99', 'paywallSavePercent:35', 20),
    ('gold_monthly', 'gold', 'month', '$29.99', 'paywallSavePercent:65', 30),
    ('gold_annual', 'gold', 'year', '$149.99', 'paywallSavePercent:85', 40),

    -- PLATINUM Plans
    ('platinum_daily', 'platinum', 'day', '$4.99', NULL, 10),
    ('platinum_weekly', 'platinum', 'week', '$19.99', 'paywallSavePercent:40', 20),
    ('platinum_monthly', 'platinum', 'month', '$49.99', 'paywallSavePercent:65', 30),
    ('platinum_annual', 'platinum', 'year', '$249.99', 'paywallSavePercent:85', 40)

ON CONFLICT (id) DO UPDATE SET
    price_display = EXCLUDED.price_display,
    savings_text = EXCLUDED.savings_text;
