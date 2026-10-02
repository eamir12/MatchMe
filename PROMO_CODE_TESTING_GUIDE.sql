-- Comprehensive Testing Guide for Promo Code System
-- Run these tests to validate the entire promo code feature

-- ============================================================================
-- SETUP: Create test codes
-- ============================================================================

-- Create a test user (if not exists)
-- Assuming test user with ID: 'test-user-uuid'

-- Create Test Promo Code 1: 20% Discount
SELECT admin_create_promo_code(
  p_code => 'TEST20',
  p_description => 'Test 20% discount',
  p_code_type => 'discount_percentage',
  p_discount_percent => 20,
  p_max_uses => 100,
  p_max_uses_per_user => 3
) AS test_code_1;

-- Create Test Promo Code 2: Limited Use Expire Soon
SELECT admin_create_promo_code(
  p_code => 'EXPIRE_SOON',
  p_description => 'Expires tomorrow',
  p_code_type => 'discount_fixed',
  p_discount_amount_cents => 1000,
  p_max_uses => 5,
  p_max_uses_per_user => 1,
  p_valid_until => now() + INTERVAL '1 day'
) AS test_code_2;

-- Create Test Promo Code 3: Future Validity
SELECT admin_create_promo_code(
  p_code => 'FUTURE_CODE',
  p_description => 'Not yet valid',
  p_code_type => 'discount_percentage',
  p_discount_percent => 50,
  p_valid_from => now() + INTERVAL '1 day',
  p_valid_until => now() + INTERVAL '2 days'
) AS test_code_3;

-- Create Test Promo Code 4: Tier Specific
SELECT admin_create_promo_code(
  p_code => 'GOLD_ONLY',
  p_description => 'Gold tier only',
  p_code_type => 'discount_percentage',
  p_discount_percent => 10,
  p_applicable_tiers => ARRAY['gold']::TEXT[],
  p_max_uses => 50
) AS test_code_4;

-- ============================================================================
-- TEST 1: BASIC VALIDATION - Valid Code
-- ============================================================================

-- Test: Validate existing code
SELECT * FROM validate_promo_code('TEST20', 'test-user-uuid'::uuid);

-- Expected Results:
-- - valid = true
-- - code_type = 'discount_percentage'
-- - discount_percent = 20
-- - error_message = NULL
-- - current_user_uses = 0 (first use)

-- ============================================================================
-- TEST 2: VALIDATION - Code Not Found
-- ============================================================================

-- Test: Try invalid code
SELECT * FROM validate_promo_code('INVALID123', 'test-user-uuid'::uuid);

-- Expected Results:
-- - valid = false
-- - error_message LIKE '%not found%'

-- ============================================================================
-- TEST 3: VALIDATION - Expired Code
-- ============================================================================

-- Manually expire a code
UPDATE public.promo_codes 
SET valid_until = now() - INTERVAL '1 day'
WHERE code = 'TEST20';

-- Test: Validate expired code
SELECT * FROM validate_promo_code('TEST20', 'test-user-uuid'::uuid);

-- Expected Results:
-- - valid = false
-- - error_message CONTAINS 'expired'

-- Restore: Make it valid again
UPDATE public.promo_codes 
SET valid_until = now() + INTERVAL '90 days'
WHERE code = 'TEST20';

-- ============================================================================
-- TEST 4: VALIDATION - Not Yet Valid
-- ============================================================================

-- Test: Try FUTURE_CODE (valid_from is tomorrow)
SELECT * FROM validate_promo_code('FUTURE_CODE', 'test-user-uuid'::uuid);

-- Expected Results:
-- - valid = false
-- - error_message CONTAINS 'not yet valid'

-- ============================================================================
-- TEST 5: VALIDATION - Tier Specific Code
-- ============================================================================

-- Test: Gold user applying gold-only code
SELECT * FROM validate_promo_code('GOLD_ONLY', 'test-user-uuid'::uuid, 'gold');

-- Expected Results:
-- - valid = true (if user is on gold tier)

-- Test: Plus user applying gold-only code
SELECT * FROM validate_promo_code('GOLD_ONLY', 'test-user-uuid'::uuid, 'plus');

-- Expected Results:
-- - valid = false
-- - error_message CONTAINS 'not applicable'

-- ============================================================================
-- TEST 6: REDEMPTION - Successful
-- ============================================================================

-- Test: Redeem valid code
SELECT * FROM redeem_promo_code(
  'TEST20',
  'test-user-uuid'::uuid,
  NULL::uuid, -- no subscription queue
  400 -- $4 discount (20% of $20)
);

-- Expected Results:
-- - success = true
-- - usage_id is NOT NULL
-- - message = 'redeemed successfully'

-- ============================================================================
-- TEST 7: REDEMPTION - User Limit Reached
-- ============================================================================

-- Manually create 3 usage records for same user/code
INSERT INTO public.promo_code_usages (promo_code_id, user_id, discount_value_cents)
SELECT pc.id, 'test-user-uuid'::uuid, 400
FROM public.promo_codes pc
WHERE pc.code = 'TEST20'
LIMIT 2; -- Already used once above + 2 more = 3 total

-- Test: Try to use after limit reached
SELECT * FROM redeem_promo_code('TEST20', 'test-user-uuid'::uuid);

-- Expected Results:
-- - success = false
-- - error_message CONTAINS 'usage limit'

-- ============================================================================
-- TEST 8: REDEMPTION - Global Limit Reached
-- ============================================================================

-- Create a limited code with max_uses = 2
SELECT admin_create_promo_code(
  p_code => 'LIMITED_USE',
  p_description => 'Only 2 uses total',
  p_code_type => 'discount_fixed',
  p_discount_amount_cents => 500,
  p_max_uses => 2
) AS test_limited;

-- Use it twice
SELECT redeem_promo_code('LIMITED_USE', 'test-user-uuid'::uuid);
SELECT redeem_promo_code('LIMITED_USE', 'other-user-uuid'::uuid);

-- Test: Try to use third time
SELECT * FROM redeem_promo_code('LIMITED_USE', 'another-user-uuid'::uuid);

-- Expected Results:
-- - success = false
-- - error_message CONTAINS 'usage limit'

-- ============================================================================
-- TEST 9: GET PROMO DETAILS (User-Facing)
-- ============================================================================

-- Test: Get details of a valid code
SELECT * FROM get_promo_code_details('TEST20');

-- Expected Results:
-- - Returns only ACTIVE codes within validity period
-- - code, description, code_type, discount_percent, etc.

-- Test: Get details of expired code
SELECT * FROM get_promo_code_details('EXPIRE_SOON');

-- Expected Results:
-- - Returns NULL or empty result if expired

-- ============================================================================
-- TEST 10: ADMIN STATISTICS
-- ============================================================================

-- Test: Get stats for TEST20 code
SELECT * FROM admin_get_promo_usage_stats(
  (SELECT id FROM public.promo_codes WHERE code = 'TEST20')
);

-- Expected Results:
-- - code = 'TEST20'
-- - total_uses > 0
-- - unique_users >= 1
-- - total_discount_cents = sum of all discounts given

-- ============================================================================
-- TEST 11: ADMIN UPDATE OPERATIONS
-- ============================================================================

-- Test: Disable a code
SELECT admin_update_promo_code(
  (SELECT id FROM public.promo_codes WHERE code = 'TEST20'),
  false -- disable
);

-- Verify: Code should not validate after disable
SELECT * FROM validate_promo_code('TEST20', 'test-user-uuid'::uuid);

-- Expected: valid = false

-- Test: Re-enable code
SELECT admin_update_promo_code(
  (SELECT id FROM public.promo_codes WHERE code = 'TEST20'),
  true -- enable
);

-- ============================================================================
-- TEST 12: EDGE CASES
-- ============================================================================

-- Test: Code with spaces and different cases
SELECT * FROM validate_promo_code('  test20  ', 'test-user-uuid'::uuid);
SELECT * FROM validate_promo_code('test20', 'test-user-uuid'::uuid);
SELECT * FROM validate_promo_code('TEST20', 'test-user-uuid'::uuid);

-- Expected: All should work (code is case-insensitive and trimmed)

-- Test: Empty code string
SELECT * FROM validate_promo_code('', 'test-user-uuid'::uuid);

-- Expected: valid = false

-- Test: NULL user (should fail)
SELECT * FROM validate_promo_code('TEST20', NULL::uuid);

-- Expected: Error about authentication

-- ============================================================================
-- TEST 13: CONCURRENCY & DATA CONSISTENCY
-- ============================================================================

-- Test: Multiple concurrent redemptions (use same discount calculation)
-- This would be tested with multiple transactions in separate sessions

-- CREATE A SIMPLE TEST:
-- 1. Start Transaction 1, count current uses
-- 2. Start Transaction 2, count current uses (should be same)
-- 3. Both redeem code 1
-- 4. Both commit
-- 5. Final count should be 2

-- ============================================================================
-- TEST 14: PERFORMANCE TESTING
-- ============================================================================

-- Test: Query performance for user with many promo uses
SELECT COUNT(*) FROM public.promo_code_usages 
WHERE user_id = 'test-user-uuid'::uuid;

-- Expected: Completes in < 100ms with indexes

-- Test: Lookup single code performance
EXPLAIN ANALYZE
SELECT * FROM public.promo_codes 
WHERE UPPER(code) = 'TEST20';

-- Expected: Uses index on code column

-- ============================================================================
-- CLEANUP: Remove test data
-- ============================================================================

-- Delete test codes
DELETE FROM public.promo_codes 
WHERE code IN ('TEST20', 'EXPIRE_SOON', 'FUTURE_CODE', 'GOLD_ONLY', 'LIMITED_USE');

-- Delete test usages (cascades automatically)
-- (Already deleted by cascade from above)

-- ============================================================================
-- VALIDATION CHECKLIST
-- ============================================================================
/*
After running all tests, verify:

Database:
  ✓ promo_codes table exists with all columns
  ✓ promo_code_usages table exists with all columns
  ✓ Indexes are created on code, user_id, promo_code_id
  ✓ RLS policies allow public read (active codes only)
  ✓ RLS policies allow admins full access
  ✓ Triggers exist for updated_at timestamp

RPC Functions:
  ✓ validate_promo_code() works correctly
  ✓ redeem_promo_code() works and creates usage records
  ✓ get_promo_code_details() returns only valid codes
  ✓ admin_create_promo_code() creates codes correctly
  ✓ admin_update_promo_code() updates fields
  ✓ admin_get_promo_usage_stats() calculates totals

Dart Service:
  ✓ promoCodeServiceProvider initializes
  ✓ validatePromoCode() calls RPC correctly
  ✓ redeemPromoCode() records usage
  ✓ getPromoCodeDetails() retrieves code info
  ✓ Static methods calculate discounts correctly

UI Widgets:
  ✓ PromoCodeInput widget renders
  ✓ Input widget validates on-demand
  ✓ AppliedPromoCodeDisplay shows discount
  ✓ PromoCodeInfoCard displays code details

Security:
  ✓ Non-admins cannot create codes
  ✓ Users can only see their own usage
  ✓ Per-user limits are enforced
  ✓ Expired codes cannot be used
  ✓ Invalid codes are rejected
*/

-- ============================================================================
-- LOAD TESTING SCRIPT (Optional)
-- ============================================================================

-- Create many test codes
-- DO $$
-- DECLARE
--   i INT := 1;
-- BEGIN
--   WHILE i <= 100 LOOP
--     INSERT INTO public.promo_codes (code, code_type, discount_percent, is_active)
--     VALUES ('TEST' || i, 'discount_percentage', 20, true);
--     i := i + 1;
--   END LOOP;
-- END $$;

-- Then test performance:
-- EXPLAIN ANALYZE SELECT * FROM public.promo_codes WHERE is_active = true;
-- EXPLAIN ANALYZE SELECT COUNT(*) FROM public.promo_code_usages;
