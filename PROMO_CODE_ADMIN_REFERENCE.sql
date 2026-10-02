-- Quick Reference Guide for Promo Code Admin Operations
-- Run these commands to manage promo codes

-- ============================================================================
-- 1. CREATE NEW PROMO CODES
-- ============================================================================

-- Example 1: 20% Off Welcome Promo
SELECT admin_create_promo_code(
  p_code => 'WELCOME20',
  p_description => '20% off your first premium subscription',
  p_code_type => 'discount_percentage',
  p_discount_percent => 20,
  p_applicable_tiers => ARRAY[]::TEXT[], -- All tiers
  p_campaign_name => 'New User Welcome',
  p_max_uses => 500,
  p_max_uses_per_user => 1,
  p_valid_from => now(),
  p_valid_until => now() + INTERVAL '90 days'
);

-- Example 2: $5 Off Any Subscription
SELECT admin_create_promo_code(
  p_code => 'SAVE5',
  p_description => '$5 discount on any subscription',
  p_code_type => 'discount_fixed',
  p_discount_amount_cents => 500, -- $5.00
  p_campaign_name => 'Holiday 2026',
  p_max_uses => 1000,
  p_max_uses_per_user => 1,
  p_valid_from => now(),
  p_valid_until => now() + INTERVAL '7 days'
);

-- Example 3: 7 Day Free Trial Extension
SELECT admin_create_promo_code(
  p_code => 'EXTEND7',
  p_description => 'Add 7 free days to your subscription',
  p_code_type => 'free_days',
  p_free_days => 7,
  p_applicable_tiers => ARRAY[]::TEXT[],
  p_campaign_name => 'Retention Campaign',
  p_max_uses => NULL, -- Unlimited
  p_max_uses_per_user => 1
);

-- Example 4: Upgrade to Gold (for Plus users)
SELECT admin_create_promo_code(
  p_code => 'UPGRADE_GOLD',
  p_description => 'Free upgrade to Gold tier for 1 month',
  p_code_type => 'tier_upgrade',
  p_upgrade_tier => 'gold',
  p_applicable_tiers => ARRAY['plus']::TEXT[], -- Only for Plus users
  p_campaign_name => 'Tier Upgrade Promotion',
  p_max_uses => 100,
  p_max_uses_per_user => 1
);

-- Example 5: Flash Sale - 50% Off (Limited Time)
SELECT admin_create_promo_code(
  p_code => 'FLASH50',
  p_description => 'Black Friday Flash Sale - 50% off',
  p_code_type => 'discount_percentage',
  p_discount_percent => 50,
  p_campaign_name => 'Black Friday 2026',
  p_max_uses => 100, -- Limited quantity
  p_max_uses_per_user => 1,
  p_valid_from => now(),
  p_valid_until => now() + INTERVAL '12 hours' -- 12 hour sale
);

-- ============================================================================
-- 2. VIEW EXISTING PROMO CODES
-- ============================================================================

-- List all active promo codes
SELECT 
  id,
  code,
  code_type,
  is_active,
  valid_until,
  max_uses,
  campaign_name,
  created_at
FROM public.promo_codes
WHERE is_active = true
ORDER BY valid_until DESC;

-- List expired promo codes
SELECT 
  code,
  valid_until,
  campaign_name
FROM public.promo_codes
WHERE valid_until < now()
ORDER BY valid_until DESC;

-- Get details for a specific code
SELECT * FROM public.promo_codes WHERE UPPER(code) = 'WELCOME20';

-- ============================================================================
-- 3. UPDATE PROMO CODES
-- ============================================================================

-- Disable a promo code (emergency stop)
SELECT admin_update_promo_code(
  p_id => 'UUID-of-code-here',
  p_is_active => false
);

-- Extend expiry date
SELECT admin_update_promo_code(
  p_id => 'UUID-of-code-here',
  p_valid_until => now() + INTERVAL '30 days'
);

-- Increase max uses (due to high demand)
SELECT admin_update_promo_code(
  p_id => 'UUID-of-code-here',
  p_max_uses => 1000
);

-- ============================================================================
-- 4. ANALYTICS & USAGE TRACKING
-- ============================================================================

-- Get comprehensive stats for a promo code
SELECT * FROM admin_get_promo_usage_stats('UUID-of-code-here');

-- View all redemptions for a code (detailed)
SELECT 
  u.name,
  u.email,
  pcu.redeemed_at,
  pcu.discount_value_cents,
  pcu.applied_tier,
  pcu.ip_address
FROM public.promo_code_usages pcu
JOIN public.users u ON u.id = pcu.user_id
WHERE pcu.promo_code_id = 'UUID-of-code-here'
ORDER BY pcu.redeemed_at DESC;

-- Total discount given by campaign
SELECT 
  pc.campaign_name,
  COUNT(*) as total_usages,
  COUNT(DISTINCT pcu.user_id) as unique_users,
  COALESCE(SUM(pcu.discount_value_cents), 0) / 100.0 as total_discount_dollars
FROM public.promo_codes pc
LEFT JOIN public.promo_code_usages pcu ON pcu.promo_code_id = pc.id
GROUP BY pc.campaign_name
ORDER BY total_discount_dollars DESC;

-- Most used codes
SELECT 
  pc.code,
  COUNT(*) as usage_count,
  COUNT(DISTINCT pcu.user_id) as unique_users,
  COALESCE(SUM(pcu.discount_value_cents), 0) / 100.0 as total_discount
FROM public.promo_codes pc
LEFT JOIN public.promo_code_usages pcu ON pcu.promo_code_id = pc.id
GROUP BY pc.code
ORDER BY usage_count DESC
LIMIT 10;

-- Revenue impact of promo codes
SELECT 
  DATE_TRUNC('day', pcu.redeemed_at) as redemption_date,
  COUNT(*) as daily_uses,
  COALESCE(SUM(pcu.discount_value_cents), 0) / 100.0 as daily_discount_cost
FROM public.promo_code_usages pcu
WHERE pcu.redeemed_at > now() - INTERVAL '30 days'
GROUP BY DATE_TRUNC('day', pcu.redeemed_at)
ORDER BY redemption_date DESC;

-- ============================================================================
-- 5. FRAUD DETECTION & MONITORING
-- ============================================================================

-- Find suspicious usage patterns (same device using multiple codes)
SELECT 
  pcu.ip_address,
  pcu.user_agent,
  COUNT(DISTINCT pcu.promo_code_id) as unique_codes_used,
  COUNT(*) as total_usage,
  LISTAGG(pc.code, ', ') AS codes_used
FROM public.promo_code_usages pcu
JOIN public.promo_codes pc ON pc.id = pcu.promo_code_id
WHERE pcu.redeemed_at > now() - INTERVAL '7 days'
GROUP BY pcu.ip_address, pcu.user_agent
HAVING COUNT(DISTINCT pcu.promo_code_id) > 3
ORDER BY COUNT(*) DESC;

-- Users with excessive activations (multiple codes)
SELECT 
  pcu.user_id,
  u.email,
  u.name,
  COUNT(*) as total_codes_used,
  SUM(pcu.discount_value_cents) / 100.0 as total_discount_received
FROM public.promo_code_usages pcu
JOIN public.users u ON u.id = pcu.user_id
WHERE pcu.redeemed_at > now() - INTERVAL '30 days'
GROUP BY pcu.user_id, u.email, u.name
HAVING COUNT(*) > 2
ORDER BY total_discount_received DESC;

-- Check for code reuse violations
SELECT 
  pcu.user_id,
  pc.code,
  COUNT(*) as times_used,
  pc.max_uses_per_user
FROM public.promo_code_usages pcu
JOIN public.promo_codes pc ON pc.id = pcu.promo_code_id
GROUP BY pcu.user_id, pc.code, pc.max_uses_per_user
HAVING COUNT(*) > pc.max_uses_per_user
ORDER BY COUNT(*) DESC;

-- ============================================================================
-- 6. CLEANUP & MAINTENANCE
-- ============================================================================

-- Archive old promo codes (mark inactive)
UPDATE public.promo_codes
SET is_active = false
WHERE valid_until < now() - INTERVAL '30 days'
  AND is_active = true;

-- Find unused codes
SELECT 
  id,
  code,
  campaign_name,
  created_at
FROM public.promo_codes pc
WHERE NOT EXISTS (
  SELECT 1 FROM public.promo_code_usages
  WHERE promo_code_id = pc.id
)
AND valid_until < now()
ORDER BY created_at DESC;

-- Delete redemption records older than 1 year (for privacy)
-- WARNING: This is permanent and affects analytics!
-- DELETE FROM public.promo_code_usages
-- WHERE redeemed_at < now() - INTERVAL '1 year';

-- ============================================================================
-- 7. REPORTING & DASHBOARDS
-- ============================================================================

-- Monthly performance summary
SELECT 
  DATE_TRUNC('month', pcu.redeemed_at) as month,
  COUNT(*) as total_redemptions,
  COUNT(DISTINCT pcu.user_id) as unique_users,
  SUM(pcu.discount_value_cents) / 100.0 as total_discount_cost,
  AVG(pcu.discount_value_cents) / 100.0 as avg_discount,
  COUNT(DISTINCT pcu.promo_code_id) as codes_active
FROM public.promo_code_usages pcu
WHERE pcu.redeemed_at > now() - INTERVAL '1 year'
GROUP BY DATE_TRUNC('month', pcu.redeemed_at)
ORDER BY month DESC;

-- Campaign performance
SELECT 
  pc.campaign_name,
  COUNT(DISTINCT pc.id) as codes_in_campaign,
  COUNT(DISTINCT pcu.user_id) as unique_users,
  COUNT(*) as total_redemptions,
  SUM(pcu.discount_value_cents) / 100.0 as total_cost,
  COUNT(DISTINCT pcu.user_id) * 1.0 / (
    SELECT COUNT(*) FROM public.users 
    WHERE created_at > NOW() - INTERVAL '3 months'
  ) * 100 as conversion_rate
FROM public.promo_codes pc
LEFT JOIN public.promo_code_usages pcu ON pcu.promo_code_id = pc.id
WHERE pc.campaign_name IS NOT NULL
GROUP BY pc.campaign_name
ORDER BY total_cost DESC;

-- Code effectiveness (conversion rate)
SELECT 
  pc.code,
  pc.campaign_name,
  COUNT(*) as redemptions,
  COUNT(DISTINCT pcu.user_id) as unique_users,
  SUM(CASE WHEN us.subscription_tier != 'free' THEN 1 ELSE 0 END) as converted_to_paid
FROM public.promo_codes pc
LEFT JOIN public.promo_code_usages pcu ON pcu.promo_code_id = pc.id
LEFT JOIN public.users us ON us.id = pcu.user_id
GROUP BY pc.code, pc.campaign_name
ORDER BY redemptions DESC;

-- ============================================================================
-- 8. COMMON OPERATIONS
-- ============================================================================

-- Get all codes that expire in the next 7 days
SELECT code, valid_until, campaign_name 
FROM public.promo_codes
WHERE valid_until BETWEEN now() AND now() + INTERVAL '7 days'
  AND is_active = true;

-- Find which users haven't used their free trial yet
SELECT u.id, u.email, u.name
FROM public.users u
WHERE u.subscription_tier = 'free'
  AND u.created_at > now() - INTERVAL '30 days'
  AND u.id NOT IN (
    SELECT DISTINCT user_id FROM public.promo_code_usages
  );

-- Total discounts given this quarter
SELECT 
  SUM(discount_value_cents) / 100.0 as total_discounts,
  COUNT(*) as total_uses,
  COUNT(DISTINCT user_id) as unique_users
FROM public.promo_code_usages
WHERE redeemed_at >= DATE_TRUNC('quarter', now())
  AND redeemed_at < DATE_TRUNC('quarter', now() + INTERVAL '1 quarter');
