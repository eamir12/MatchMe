import 'package:matchme/providers/locale_provider.dart';

String localizePromoDiscountDescription(
  LocalizationState l10n, {
  required String codeType,
  int? amount,
  int? discountPercent,
  int? discountAmountCents,
  int? freeDays,
  String? upgradeTier,
}) {
  final resolvedAmount = switch (codeType) {
    'discount_percentage' => discountPercent ?? amount,
    'discount_fixed' => discountAmountCents ?? amount,
    'free_days' => freeDays ?? amount,
    _ => amount,
  };

  switch (codeType) {
    case 'discount_percentage':
      return l10n.getString(
        'promoDiscountPercentageFormat',
        params: {'amount': '${resolvedAmount ?? 0}'},
      );
    case 'discount_fixed':
      final dollars = ((resolvedAmount ?? 0) / 100);
      final formattedAmount =
          '\$${dollars.toStringAsFixed(dollars.truncateToDouble() == dollars ? 0 : 2)}';
      return l10n.getString(
        'promoDiscountFixedFormat',
        params: {'amount': formattedAmount},
      );
    case 'free_days':
      final dayCount = resolvedAmount ?? 1;
      return l10n.getPluralString(
        'promoDiscountFreeDaysFormat',
        dayCount,
        countParam: 'days',
      );
    case 'tier_upgrade':
      return l10n.getString(
        'promoDiscountTierUpgradeFormat',
        params: {'tier': upgradeTier ?? ''},
      );
    default:
      return l10n.getString('promoDiscountSpecialOffer');
  }
}

String localizePromoCodeExpiry(LocalizationState l10n, DateTime? validUntil) {
  if (validUntil == null) {
    return l10n.getString('promoCodeNoExpiry');
  }

  final now = DateTime.now();
  if (validUntil.isBefore(now)) {
    return l10n.getString('promoCodeStatusExpired');
  }

  final difference = validUntil.difference(now);
  if (difference.inDays >= 1) {
    final days = difference.inDays;
    return l10n.getPluralString(
      'promoCodeExpiresIn',
      days,
      countParam: 'days',
    );
  }

  if (difference.inHours >= 1) {
    return l10n.getPluralString(
      'promoCodeExpiresInHours',
      difference.inHours,
      countParam: 'hours',
    );
  }

  return l10n.getString('promoCodeExpiresToday');
}

String localizePromoCodeError(LocalizationState l10n, String? rawMessage) {
  if (rawMessage == null || rawMessage.trim().isEmpty) {
    return l10n.getString('promoCodeInvalidFallback');
  }

  final trimmed = rawMessage.trim();

  if (trimmed == 'Promo code not found' ||
      trimmed == 'Invalid or inactive promo code') {
    return l10n.getString('promoCodeInvalid');
  }
  if (trimmed == 'Promo code is not active') {
    return l10n.getString('promoCodeInvalid');
  }
  if (trimmed == 'Promo code is not yet valid') {
    return l10n.getString('promoCodeNotYetValid');
  }
  if (trimmed == 'Promo code has expired') {
    return l10n.getString('promoCodeExpired');
  }
  if (trimmed == 'Promo code has reached its usage limit' ||
      trimmed == 'Code limit reached') {
    return l10n.getString('promoCodeGlobalLimitReached');
  }
  if (trimmed ==
          'You have already used this promo code the maximum number of times' ||
      trimmed == 'Usage limit exceeded') {
    return l10n.getString('promoCodeLimitReached');
  }
  if (trimmed.startsWith('This promo code is not applicable for the ') &&
      trimmed.endsWith(' tier')) {
    final tier = trimmed
        .replaceFirst('This promo code is not applicable for the ', '')
        .replaceFirst(' tier', '');
    return l10n.getString(
      'promoCodeNotApplicableForTier',
      params: {'tier': tier},
    );
  }
  if (trimmed == 'Not authenticated') {
    return l10n.getString('authUnauthorized');
  }
  if (trimmed == 'Promo code validation failed' ||
      trimmed == 'Promo code redemption failed' ||
      trimmed.startsWith('Failed to validate code:') ||
      trimmed.startsWith('Failed to redeem code:') ||
      trimmed.contains('PostgrestException')) {
    return l10n.getString('promoCodeInvalidFallback');
  }

  return trimmed;
}
