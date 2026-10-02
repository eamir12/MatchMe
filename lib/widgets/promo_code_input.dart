import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/promo_code_service.dart';
import 'package:matchme/utils/promo_code_localization.dart';

/// Reusable widget for displaying and applying promo codes
class PromoCodeInput extends ConsumerStatefulWidget {
  /// Callback when a promo code is validated
  final Function(PromoCodeValidationResult) onValidated;

  /// Optional tier to validate code against
  final String? applicableTier;

  /// Whether to automatically apply valid codes
  final bool autoApply;

  /// Custom label (if null, uses localized default)
  final String? customLabel;

  const PromoCodeInput({
    super.key,
    required this.onValidated,
    this.applicableTier,
    this.autoApply = false,
    this.customLabel,
  });

  @override
  ConsumerState<PromoCodeInput> createState() => _PromoCodeInputState();
}

class _PromoCodeInputState extends ConsumerState<PromoCodeInput> {
  late TextEditingController _codeController;
  bool _isValidating = false;
  PromoCodeValidationResult? _lastValidation;

  @override
  void initState() {
    super.initState();
    _codeController = TextEditingController();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _validateCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ref.read(localizationProvider).getString('promoCodeEmpty'),
          ),
        ),
      );
      return;
    }

    setState(() => _isValidating = true);

    try {
      final service = ref.read(promoCodeServiceProvider);
      final result = await service.validatePromoCode(
        code,
        forTier: widget.applicableTier,
      );

      if (!mounted) return;

      setState(() {
        _lastValidation = result;
        _isValidating = false;
      });

      if (result.valid) {
        widget.onValidated(result);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ref.read(localizationProvider).getString('promoCodeValid'),
            ),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(localizePromoCodeError(l10n, result.errorMessage)),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isValidating = false);
      final l10n = ref.read(localizationProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.getString('promoCodeValidationError', params: {'error': '$e'}),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final validationMessage = _lastValidation == null
        ? null
        : (_lastValidation!.valid
              ? localizePromoDiscountDescription(
                  l10n,
                  codeType: _lastValidation!.codeType ?? '',
                  discountPercent: _lastValidation!.discountPercent,
                  discountAmountCents: _lastValidation!.discountAmountCents,
                  freeDays: _lastValidation!.freeDays,
                  upgradeTier: _lastValidation!.upgradeTier,
                  amount: _lastValidation!.amount,
                )
              : localizePromoCodeError(l10n, _lastValidation!.errorMessage));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.customLabel ?? l10n.getString('promoCodeLabel'),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _codeController,
                decoration: InputDecoration(
                  hintText: l10n.getString('promoCodePlaceholder'),
                  filled: true,
                  fillColor: theme.colorScheme.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: theme.colorScheme.outline),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  enabled: !_isValidating,
                ),
                textCapitalization: TextCapitalization.characters,
                onChanged: (_) {
                  setState(() => _lastValidation = null);
                },
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
              onPressed: _isValidating ? null : _validateCode,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.getString('promoCodeApplyBtn')),
                  const SizedBox(width: 8),
                  _isValidating
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(
                              theme.colorScheme.primary,
                            ),
                          ),
                        )
                      : const Icon(Icons.check),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Show validation details if available
        if (_lastValidation != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _lastValidation!.valid
                  ? Colors.green.withValues(alpha: 0.1)
                  : Colors.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _lastValidation!.valid
                    ? Colors.green.withValues(alpha: 0.3)
                    : Colors.red.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _lastValidation!.valid
                          ? Icons.check_circle
                          : Icons.error_outline,
                      color: _lastValidation!.valid ? Colors.green : Colors.red,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        validationMessage ?? '',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _lastValidation!.valid
                              ? Colors.green
                              : Colors.red,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Widget showing applied promo code with details
class AppliedPromoCodeDisplay extends ConsumerWidget {
  final PromoCodeValidationResult validation;
  final VoidCallback onRemove;

  const AppliedPromoCodeDisplay({
    super.key,
    required this.validation,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = ref.watch(localizationProvider);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.local_offer, color: Colors.green, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.getString('promoCodeApplied'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.green,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  localizePromoDiscountDescription(
                    l10n,
                    codeType: validation.codeType ?? '',
                    discountPercent: validation.discountPercent,
                    discountAmountCents: validation.discountAmountCents,
                    freeDays: validation.freeDays,
                    upgradeTier: validation.upgradeTier,
                    amount: validation.amount,
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close),
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

/// Promo code info card for displaying available promotions
class PromoCodeInfoCard extends ConsumerWidget {
  final PromoCodeDetailsResult details;
  final VoidCallback onApply;

  const PromoCodeInfoCard({
    super.key,
    required this.details,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = ref.watch(localizationProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  details.code,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                if (!details.isExpired)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      localizePromoCodeExpiry(l10n, details.validUntil),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.blue,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      l10n.getString('promoCodeStatusExpired'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.red,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (details.description != null) ...[
              Text(details.description!, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
            ],
            Text(
              localizePromoDiscountDescription(
                l10n,
                codeType: details.codeType,
                discountPercent: details.discountPercent,
                discountAmountCents: details.discountAmountCents,
                freeDays: details.freeDays,
                upgradeTier: details.upgradeTier,
                amount: details.amount,
              ),
              style: theme.textTheme.titleSmall?.copyWith(
                color: Colors.green,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: details.isExpired ? null : onApply,
                child: Text(
                  details.isExpired
                      ? l10n.getString('promoCodeButtonExpired')
                      : l10n.getString('promoCodeApplyBtn'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
