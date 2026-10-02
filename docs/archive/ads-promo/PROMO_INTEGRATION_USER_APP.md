# Promo Code UI - Integration Guide for MatchMe User App

## Quick Start

The promo code UI is ready to integrate into your subscription/payment flow. Follow these steps:

## Step 1: Import the Payment Screen

```dart
import 'package:matchme/screens/subscription/subscription_payment_screen.dart';
```

## Step 2: Add Route to Your Navigation

In your main navigation/routing setup:

```dart
// In your router configuration or main.dart routes
'/subscription-payment': (context) => SubscriptionPaymentScreen(
  tier: 'gold',        // 'plus', 'gold', or 'platinum'
  duration: 'monthly', // 'monthly' or 'annual'
  priceInCents: 2999,  // $29.99
),
```

## Step 3: Navigate to Payment Screen

From your subscription tiers screen:

```dart
Navigator.of(context).pushNamed(
  '/subscription-payment',
  arguments: {
    'tier': 'gold',
    'duration': 'monthly',
    'priceInCents': 2999,
  },
);
```

## Integration Points

### Option A: In Subscription Tier Selection Screen

```dart
// In your existing subscription tiers screen
class SubscriptionTiersScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GridView(
      children: [
        _buildTierCard(
          'Gold',
          2999,
          onSubscribe: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => SubscriptionPaymentScreen(
                  tier: 'gold',
                  duration: 'monthly',
                  priceInCents: 2999,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
```

### Option B: From Settings → Premium Screen

```dart
// In settings_screen.dart, when user taps "Upgrade to Premium"
onPressed: () {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => const SubscriptionPaymentScreen(
        tier: 'gold',
        duration: 'monthly',
        priceInCents: 2999,
      ),
    ),
  );
},
```

### Option C: From Home Screen Banner

```dart
// In home_screen.dart, when user taps premium banner
Container(
  child: ElevatedButton(
    onPressed: () {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => const SubscriptionPaymentScreen(
            tier: 'platinum',
            duration: 'monthly',
            priceInCents: 9999,
          ),
        ),
      );
    },
    child: Text('Upgrade Now'),
  ),
)
```

## UI Components Available

### 1. PromoCodeInput Widget
Standalone text field with validation:

```dart
PromoCodeInput(
  applicableTier: 'gold',  // Optional: restrict to tier
  onValidated: (result) {
    // Handle validation result
    print('Code: ${result.discountDescription}');
  },
  customLabel: 'Have a coupon?',  // Optional custom label
)
```

### 2. AppliedPromoCodeDisplay Widget
Show applied code details:

```dart
if (appliedPromo != null && appliedPromo!.valid)
  AppliedPromoCodeDisplay(
    validation: appliedPromo!,
    onRemove: () {
      // Handle removal
    },
  ),
```

### 3. PromoCodeInfoCard Widget
Display promotional code details:

```dart
PromoCodeInfoCard(
  details: promo CodeDetails,
  onApply: () {
    // Handle apply button
  },
)
```

## Code Flow Example

```dart
class MyPaymentScreen extends ConsumerStatefulWidget {
  @override
  ConsumerState<MyPaymentScreen> createState() => _MyPaymentScreenState();
}

class _MyPaymentScreenState extends ConsumerState<MyPaymentScreen> {
  PromoCodeValidationResult? _appliedPromo;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Your subscription details...
        
        // Promo input
        PromoCodeInput(
          onValidated: (result) {
            setState(() => _appliedPromo = result);
          },
        ),
        
        // Show applied promo
        if (_appliedPromo?.valid ?? false)
          AppliedPromoCodeDisplay(
            validation: _appliedPromo!,
            onRemove: () => setState(() => _appliedPromo = null),
          ),
        
        // Price calculation
        Text('Final Price: \$${_calculateFinalPrice()}'),
        
        // Payment button
        ElevatedButton(
          onPressed: _processPayment,
          child: Text('Pay Now'),
        ),
      ],
    );
  }

  double _calculateFinalPrice() {
    const basePrice = 29.99;
    if (_appliedPromo == null || !_appliedPromo!.valid) {
      return basePrice;
    }
    
    final discount = PromoCodeService.calculateDiscount(
      _appliedPromo!.codeType ?? '',
      (basePrice * 100).toInt(),
      discountPercent: _appliedPromo!.discountPercent,
    );
    
    return basePrice - (discount / 100);
  }

  Future<void> _processPayment() async {
    // 1. Process payment with Stripe/RevenueCat/etc.
    
    // 2. Redeem promo code after payment succeeds
    if (_appliedPromo != null) {
      final service = ref.read(promoCodeServiceProvider);
      await service.redeemPromoCode(
        _appliedPromo!.code,
        discountValueCents: _calculateDiscountAmount(),
      );
    }
  }

  int _calculateDiscountAmount() {
    const basePrice = 2999; // cents
    return PromoCodeService.calculateDiscount(
      _appliedPromo!.codeType ?? '',
      basePrice,
      discountPercent: _appliedPromo!.discountPercent,
    );
  }
}
```

## Customization

### Custom Styling

Override colors in your theme:

```dart
// In your theme definition
ThemeData(
  inputDecorationTheme: InputDecorationTheme(
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
    ),
  ),
)
```

### Custom Labels

Pass `customLabel` to override default text:

```dart
PromoCodeInput(
  customLabel: 'Got a discount code? 🎉',
  // ...
)
```

### Multi-Language Support

Already integrated! Uses your localization provider:

```dart
// Automatically translated to:
// - promoCodeLabel
// - promoCodePlaceholder
// - promoCodeValid
// - etc.
```

## Testing

### Test with Sample Codes

Create these codes in your database to test:

```sql
-- 20% off welcome code
SELECT admin_create_promo_code(
  'WELCOME20', 'Welcome discount', 'discount_percentage',
  20, NULL, NULL, NULL, ARRAY[]::TEXT[], NULL, 500, 1
);

-- $5 off any subscription
SELECT admin_create_promo_code(
  'SAVE5', 'Save $5', 'discount_fixed',
  NULL, 500, NULL, NULL, ARRAY[]::TEXT[], NULL, 1000, 3
);
```

### In App Testing

1. Navigate to payment screen
2. Enter test code: `WELCOME20`
3. Verify discount shows correctly
4. Complete payment flow
5. Verify promo was redeemed

## Error Handling

The widgets handle errors automatically, but you can customize:

```dart
PromoCodeInput(
  onValidated: (result) {
    if (!result.valid) {
      print('Validation failed: ${result.errorMessage}');
      // Show custom error message
      showErrorDialog(result.errorMessage);
    }
  },
)
```

## Best Practices

1. **Always validate before payment** - Don't apply discounts in UI only
2. **Redeem after payment succeeds** - Only call redeemPromoCode after confirmed transaction
3. **Show savings clearly** - Users love seeing how much they save
4. **Handle edge cases** - Expired codes, usage limits, tier restrictions
5. **Test with real codes** - Use your admin dashboard to create test codes

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Widget not showing | Check imports and route setup |
| Validation always fails | Verify code exists: `SELECT * FROM promo_codes WHERE code = 'YOUR_CODE'` |
| Discount not calculating | Check code type matches calculation logic |
| Promo service not found | Ensure `promoCodeServiceProvider` is in scope |
| Locale strings missing | Run translation SQL files first |

## Files Reference

- **Service**: `lib/services/promo_code_service.dart`
- **Widgets**: `lib/widgets/promo_code_input.dart`
- **Screen**: `lib/screens/subscription/subscription_payment_screen.dart`
- **Translations**: Already included via `add_promo_code_translations.sql`

## Next Steps

1. ✅ Database schema (already created)
2. ✅ Backend service (already created)
3. ✅ UI widgets (already created)
4. ⏳ **Integrate into your app** (YOU ARE HERE)
5. ⏳ Test with real codes
6. ⏳ Deploy to production

---

**Need help with payment provider integration?** See PROMO_CODE_SYSTEM_GUIDE.md for details on calculating discounts and redeeming codes.
