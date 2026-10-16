import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/widgets/promo_code_input.dart';
import 'package:matchme/services/promo_code_service.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/widgets/safe_text.dart';

/// User-facing screen for subscription purchase with promo code support
/// Integrate this into your subscription/payment flow
class SubscriptionPaymentScreen extends ConsumerStatefulWidget {
  final String tier; // 'plus', 'gold', 'platinum'
  final String duration; // 'monthly', 'annual'
  final int priceInCents; // e.g., 2999 for $29.99

  const SubscriptionPaymentScreen({
    super.key,
    required this.tier,
    required this.duration,
    required this.priceInCents,
  });

  @override
  ConsumerState<SubscriptionPaymentScreen> createState() =>
      _SubscriptionPaymentScreenState();
}

class _SubscriptionPaymentScreenState
    extends ConsumerState<SubscriptionPaymentScreen> {
  PromoCodeValidationResult? _appliedPromo;
  bool _isProcessing = false;

  int get _finalPrice {
    if (_appliedPromo == null || !_appliedPromo!.valid) {
      return widget.priceInCents;
    }

    final discount = PromoCodeService.calculateDiscount(
      _appliedPromo!.codeType ?? '',
      widget.priceInCents,
      amount: _appliedPromo!.amount,
    );

    return widget.priceInCents - discount;
  }

  int get _savingsInCents => widget.priceInCents - _finalPrice;

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final promoCodesEnabled =
        ref.watch(appConfigProvider)['promo_codes_enabled']?.toLowerCase() ==
        'true';

    return Scaffold(
      appBar: AppBar(title: ShrinkText(l10n.getString('paywallTitle')), elevation: 0),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Tier and duration display
            _buildTierCard(context, l10n),

            const SizedBox(height: 24),

            // PROMO CODE INPUT - Main integration point
            if (promoCodesEnabled)
              PromoCodeInput(
                applicableTier: widget.tier,
                customLabel: l10n.getString('promoCodeSection'),
                onValidated: (result) {
                  setState(() => _appliedPromo = result);
                },
              ),

            const SizedBox(height: 24),

            // Show applied promo details
            if (promoCodesEnabled &&
                _appliedPromo != null &&
                _appliedPromo!.valid)
              AppliedPromoCodeDisplay(
                validation: _appliedPromo!,
                onRemove: () {
                  setState(() => _appliedPromo = null);
                },
              ),

            const SizedBox(height: 24),

            // Price breakdown card
            _buildPriceBreakdown(context, l10n),

            const SizedBox(height: 24),

            // Subscribe button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isProcessing ? null : _proceedToPayment,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isProcessing
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.getString('paywallSubscribe')),
              ),
            ),

            const SizedBox(height: 16),

            // Terms & Privacy
            Center(
              child: Text(
                l10n.getString('paywallTermsAndPrivacy'),
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTierCard(BuildContext context, dynamic l10n) {
    final theme = Theme.of(context);
    final tierName = _getTierDisplayName();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tierName,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _getDurationText(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '\$${(widget.priceInCents / 100).toStringAsFixed(2)}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(height: 1),
            const SizedBox(height: 12),
            Text(
              l10n.getString('paywallFeaturesTitle'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPriceBreakdown(BuildContext context, dynamic l10n) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(l10n.getString('promoCodeCurrentDiscount')),
              Text(
                '\$${(widget.priceInCents / 100).toStringAsFixed(2)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          if (_savingsInCents > 0) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.getString('promoCodeSavings'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.green,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '-\$${(_savingsInCents / 100).toStringAsFixed(2)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 1),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.getString('promoCodeYouPay'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '\$${(_finalPrice / 100).toStringAsFixed(2)}',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _getTierDisplayName() {
    final l10n = ref.read(localizationProvider);
    switch (widget.tier) {
      case 'plus':
        return l10n.getString('tierPlusTitle');
      case 'gold':
        return l10n.getString('tierGoldTitle');
      case 'platinum':
        return l10n.getString('tierPlatinumTitle');
      default:
        return widget.tier;
    }
  }

  String _getDurationText() {
    final l10n = ref.read(localizationProvider);
    switch (widget.duration) {
      case 'monthly':
        return l10n.getString('paywallPeriodMonthly');
      case 'annual':
        return l10n.getString('paywallPeriodAnnual');
      default:
        return widget.duration;
    }
  }

  Future<void> _proceedToPayment() async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      // TODO: Implement your payment processing logic here
      // 1. Process payment with payment provider (Stripe, RevenueCat, etc.)
      // 2. Get subscription queue ID from successful payment
      // 3. Redeem promo code if applied

      if (_appliedPromo != null &&
          _appliedPromo!.valid &&
          _appliedPromo!.code != null) {
        final service = ref.read(promoCodeServiceProvider);
        final result = await service.redeemPromoCode(
          _appliedPromo!.code!,
          discountValueCents: _savingsInCents,
        );

        if (!result.success) {
          if (mounted) {
            final l10n = ref.read(localizationProvider);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  l10n.getString(
                    'paymentPromoRedemptionWarning',
                    params: {'error': result.errorMessage ?? 'unknown'},
                  ),
                ),
                backgroundColor: Colors.orange,
              ),
            );
          }
          // Note: Don't block payment, just log the issue
        }
      }

      // Navigate to success screen
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/subscription-success');
      }
    } catch (e) {
      if (mounted) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.getString('paymentFailed', params: {'error': e.toString()}),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }
}
