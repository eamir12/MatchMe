# Promo Code System Implementation Guide

## Overview

This document describes the **multi-use promo code system** added to the MatchMe app. It supports various discount types, usage limits, temporal constraints, and comprehensive analytics.

## Features

### Core Features
- **Multi-Use Codes**: Each code can be used unlimited times (or limited per configuration)
- **Per-User Limits**: Prevent abuse by limiting uses per user
- **Discount Types**:
  - Percentage discount (e.g., 20% off)
  - Fixed amount discount (e.g., $5 off)
  - Free days (e.g., 3 days free)
  - Tier upgrades (e.g., upgrade to Gold tier)
- **Tier-Specific**: Codes can be restricted to specific subscription tiers
- **Temporal Constraints**: Start/end dates for time-limited campaigns
- **Campaign Tracking**: Group codes by marketing campaign
- **Usage Analytics**: Track who used what code and when

### Security Features
- RLS policies to prevent unauthorized access
- Server-side validation to prevent fraud
- Admin-only functions for code creation
- Device/IP tracking for abuse detection
- Single-use enforcement per user

## Database Schema

### Tables

#### `promo_codes`
Stores promotional code definitions:
```sql
- id: UUID (primary key)
- code: TEXT (unique, case-insensitive)
- code_type: TEXT ('discount_percentage', 'discount_fixed', 'free_days', 'tier_upgrade')
- discount_percent: INT (0-100)
- discount_amount_cents: INT
- free_days: INT
- upgrade_tier: TEXT
- applicable_tiers: TEXT[] (empty = all tiers)
- max_uses: INT (NULL = unlimited)
- max_uses_per_user: INT (default: 1)
- valid_from: TIMESTAMPTZ
- valid_until: TIMESTAMPTZ (default: +90 days)
- is_active: BOOLEAN
- campaign_name: TEXT
- created_by: UUID (references users.id)
- created_at, updated_at: TIMESTAMPTZ
```

#### `promo_code_usages`
Tracks individual redemptions:
```sql
- id: UUID (primary key)
- promo_code_id: UUID (references promo_codes.id)
- user_id: UUID (references users.id)
- subscription_queue_id: UUID (optional, links to subscription)
- redeemed_at: TIMESTAMPTZ
- discount_value_cents: INT (actual discount applied)
- applied_tier: TEXT (user's tier when applied)
- ip_address, user_agent: TEXT (for tracking)
- created_at: TIMESTAMPTZ
```

## Setup Instructions

### Step 1: Run Database Migrations

Execute the SQL files in order:

```bash
# 1. Create tables and RLS policies
psql -U postgres -d matchme < create_promo_codes_table.sql

# 2. Create RPC functions
psql -U postgres -d matchme < create_promo_code_functions.sql

# 3. Add translations
psql -U postgres -d matchme < add_promo_code_translations.sql
```

Or in Supabase Dashboard:
1. Go to SQL Editor
2. Create new query for each file
3. Run them in order

### Step 2: Add Dart Service

The `lib/services/promo_code_service.dart` file is already created. It provides:
- `validatePromoCode()` - Validate without redeeming
- `redeemPromoCode()` - Record redemption after payment
- `getPromoCodeDetails()` - Get user-facing code info

### Step 3: Add UI Widgets

The `lib/widgets/promo_code_input.dart` file provides:
- `PromoCodeInput` - Text input field with validation display
- `AppliedPromoCodeDisplay` - Shows applied code with discount
- `PromoCodeInfoCard` - Displays available promo details

### Step 4: Integrate Into Your Screens

#### In Subscription/Payment Screens

```dart
import 'package:matchme/widgets/promo_code_input.dart';
import 'package:matchme/services/promo_code_service.dart';

class PaymentScreen extends ConsumerStatefulWidget {
  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  PromoCodeValidationResult? _appliedPromoCode;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Subscription selection...
        
        const SizedBox(height: 24),
        
        // Promo code input
        PromoCodeInput(
          applicableTier: selectedTier, // e.g., 'gold'
          onValidated: (result) {
            setState(() => _appliedPromoCode = result);
            // Recalculate price with discount
            _updatePrice();
          },
        ),
        
        const SizedBox(height: 16),
        
        // Show applied code details
        if (_appliedPromoCode != null && _appliedPromoCode!.valid)
          AppliedPromoCodeDisplay(
            validation: _appliedPromoCode!,
            onRemove: () {
              setState(() => _appliedPromoCode = null);
              _updatePrice();
            },
          ),
        
        const SizedBox(height: 24),
        
        // Price display with discount applied
        _buildPriceDisplay(),
        
        // Proceed to payment button
        ElevatedButton(
          onPressed: _proceedToPayment,
          child: Text('Continue to Payment'),
        ),
      ],
    );
  }

  Widget _buildPriceDisplay() {
    final basePrice = ... // Your subscription price
    int finalPrice = basePrice;
    
    if (_appliedPromoCode != null && _appliedPromoCode!.valid) {
      final discount = PromoCodeService.calculateDiscount(
        _appliedPromoCode!.codeType ?? '',
        basePrice,
        discountPercent: _appliedPromoCode!.discountPercent,
        discountAmountCents: _appliedPromoCode!.discountAmountCents,
      );
      finalPrice = basePrice - discount;
    }
    
    return Column(
      children: [
        Text('Price: \$${(finalPrice / 100).toStringAsFixed(2)}'),
        if (_appliedPromoCode != null && _appliedPromoCode!.valid)
          Text(
            'Savings: \$${((basePrice - finalPrice) / 100).toStringAsFixed(2)}',
            style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
          ),
      ],
    );
  }

  Future<void> _proceedToPayment() async {
    // Process payment with the selected promo code
    // After successful payment, redeem the code:
    
    if (_appliedPromoCode != null && _appliedPromoCode!.codeId != null) {
      final service = ref.read(promoCodeServiceProvider);
      final result = await service.redeemPromoCode(
        _appliedPromoCode!.codeId!, // The code ID from validation
        subscriptionQueueId: subscriptionQueueId, // Your subscription record ID
        discountValueCents: discountApplied,
      );
      
      if (!result.success) {
        print('Failed to redeem promo code: ${result.errorMessage}');
      }
    }
  }
}
```

## Admin API Usage

### Create a Promo Code

```sql
SELECT * FROM admin_create_promo_code(
  p_code => 'WELCOME20',
  p_description => 'Welcome offer for new users',
  p_code_type => 'discount_percentage',
  p_discount_percent => 20,
  p_applicable_tiers => ARRAY['plus', 'gold', 'platinum'],
  p_campaign_name => 'Q1_2026_Launch',
  p_max_uses => 1000,
  p_max_uses_per_user => 1,
  p_valid_from => now(),
  p_valid_until => now() + INTERVAL '30 days'
);
```

### Get Promo Code Stats

```sql
SELECT * FROM admin_get_promo_usage_stats(
  p_promo_code_id => 'code-uuid-here'
);
```

### Update Promo Code

```sql
SELECT * FROM admin_update_promo_code(
  p_id => 'code-uuid-here',
  p_is_active => false,  -- Disable code
  p_valid_until => now() + INTERVAL '15 days'
);
```

### List All Usages for a Code

```sql
SELECT 
  user_id,
  redeemed_at,
  discount_value_cents,
  applied_tier
FROM public.promo_code_usages
WHERE promo_code_id = 'code-uuid-here'
ORDER BY redeemed_at DESC;
```

## API Reference

### Dart Service Functions

#### `validatePromoCode(code, forTier?, userId?)`
- **Purpose**: Validate a promo code without using it
- **Returns**: `PromoCodeValidationResult` with validation status
- **Use**: Before payment to show user if code is valid and what benefit they get
- **Example**:
  ```dart
  final result = await promoCodeService.validatePromoCode(
    'WELCOME20',
    forTier: 'gold',
  );
  if (result.valid) {
    print('Discount: ${result.discountDescription}');
  }
  ```

#### `redeemPromoCode(code, userId?, subscriptionQueueId?, discountValueCents?)`
- **Purpose**: Record a promo code redemption (after payment confirmed)
- **Returns**: `PromoCodeRedemptionResult` with usage record ID
- **Use**: After successful payment to track usage
- **Example**:
  ```dart
  final result = await promoCodeService.redeemPromoCode(
    'WELCOME20',
    subscriptionQueueId: queueId,
    discountValueCents: 2000, // $20 discount
  );
  ```

#### `getPromoCodeDetails(code)`
- **Purpose**: Get user-facing details about a promo code
- **Returns**: `PromoCodeDetailsResult` with code info
- **Use**: Display promo code info cards
- **Example**:
  ```dart
  final details = await promoCodeService.getPromoCodeDetails('WELCOME20');
  print('${details.code}: ${details.description}');
  print('Expires: ${details.daysUntilExpiry}');
  ```

## Example Promo Codes

### 1. Welcome Discount
```dart
await promo.validatePromoCode('WELCOME20');
// Result: 20% off first subscription, valid for all tiers
```

### 2. Limited Time Flash Sale
```dart
await promo.validatePromoCode('FRIDAY50');
// Result: 50% off, max 100 uses globally, 1 per user
```

### 3. Tier Upgrade
```dart
await promo.validatePromoCode('UPGRADE_GOLD');
// Result: Upgrade to Gold tier (if currently on Plus)
```

### 4. Free Trial Extension
```dart
await promo.validatePromoCode('EXTEND7');
// Result: 7 free days added to subscription
```

## Translations

All UI strings have been added to the translations table in 3 languages:
- **English (en)**: From `promoCodeLabel` to `promoCodeDescription`
- **Spanish (es)**: Full translations for all terms
- **Hebrew (he)**: Full RTL translations for all terms

Access via `l10n.getString('promoCodeLabel')`

## Best Practices

### For Users
1. **Clear Communication**: Show the discount amount before asking for payment
2. **One-Time Use**: Default to 1 use per user to prevent abuse
3. **Expiry Warnings**: Show countdown for codes expiring soon
4. **Auto-Apply**: Consider auto-applying valid codes in premium flow

### For Admins
1. **Campaign Tracking**: Always set `campaign_name` for analytics
2. **Per-User Limits**: Keep `max_uses_per_user = 1` unless business requires otherwise
3. **Temporal Limits**: Set appropriate `valid_from` and `valid_until` dates
4. **Descriptive Codes**: Use memorable codes (e.g., `HOLIDAY2026`, `SUMMER20`)
5. **Global Limits**: Set `max_uses` to prevent over-discounting
6. **Monitor Usage**: Regularly check `admin_get_promo_usage_stats()` for spending impact

## Fraud Prevention

The system includes built-in fraud prevention:

1. **Per-User Limits**: Each user can only use a code N times (default 1)
2. **Global Limits**: Total uses can be capped
3. **Device Tracking**: IP and user agent logged for suspicious patterns
4. **RLS Policies**: Users can only see their own usage
5. **Time Constraints**: Codes have valid periods
6. **Tier Restrictions**: Codes can be restricted to specific tiers

## Troubleshooting

### Code Not Found
- Check spelling and capitalization (codes are case-insensitive but should be uppercase)
- Verify code is active in database
- Check if code has expired

### "Maximum Uses Reached"
- User has already used this code once
- Admin should create new code or adjust `max_uses_per_user`

### Discount Not Applied on Payment
- Validate code BEFORE taking payment
- Redeem code AFTER payment succeeds
- Pass correct `subscriptionQueueId` and `discountValueCents`

### Performance Issues
- Indexes are created on frequently queried columns
- Consider caching valid codes in local storage
- Use `validate_promo_code()` sparingly during typing

## Future Enhancements

1. **Referral Integration**: Auto-generate promo codes for referrals
2. **Bulk Creation**: Admin tool to create codes in bulk
3. **A/B Testing**: Track conversion with different codes
4. **Email Distribution**: Send codes to user segments
5. **Social Sharing**: Generate unique codes per referral link
6. **Tiered Discounts**: Different discounts for different tiers
7. **Usage Patterns**: ML-based fraud detection

## Files Created/Modified

1. **`create_promo_codes_table.sql`** - Database schema
2. **`create_promo_code_functions.sql`** - RPC functions
3. **`add_promo_code_translations.sql`** - i18n strings
4. **`lib/services/promo_code_service.dart`** - Dart service
5. **`lib/widgets/promo_code_input.dart`** - UI components

## Support

For issues or questions about the promo code system, refer to the SQL comments and Dart docstrings in the implementation files.
