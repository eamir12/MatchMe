import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final promoCodeServiceProvider = Provider((ref) => PromoCodeService());

class PromoCodeService {
  final SupabaseClient _supabase = Supabase.instance.client;

  /// Validates a promo code without redeeming it
  /// Returns validation status and code details
  Future<PromoCodeValidationResult> validatePromoCode(
    String code, {
    String? forTier,
    String? userId,
  }) async {
    try {
      final currentUserId = userId ?? _supabase.auth.currentUser?.id;
      if (currentUserId == null) {
        return PromoCodeValidationResult(
          valid: false,
          errorMessage: 'User not authenticated',
        );
      }

      final response = await _supabase.rpc(
        'validate_promo_code',
        params: {
          'p_code': code,
          'p_user_id': currentUserId,
          'p_for_tier': forTier,
        },
      );

      if (response == null || (response is List ? response.isEmpty : false)) {
        return PromoCodeValidationResult(
          valid: false,
          errorMessage: 'Invalid response from server',
        );
      }

      // Handle both list and map responses from Supabase
      final data = response is List ? response.first : response;

      return PromoCodeValidationResult(
        valid: data['valid'] == true,
        errorMessage: data['error_message'] as String?,
        code: code,
        codeId: data['code_id'] as String?,
        codeType: data['code_type'] as String?,
        amount: data['amount'] as int?,
        upgradeTier: data['upgrade_tier'] as String?,
        maxUsesPerUser: data['max_uses_per_user'] as int?,
        currentUserUses: data['current_user_uses'] as int?,
        totalUses: data['total_uses'] as int?,
        maxUses: data['max_uses'] as int?,
      );
    } catch (e) {
      debugPrint('Error validating promo code: $e');
      return PromoCodeValidationResult(
        valid: false,
        errorMessage: 'Promo code validation failed',
      );
    }
  }

  /// Redeems a promo code after purchase/subscription confirmation
  /// Should only be called after payment is confirmed
  Future<PromoCodeRedemptionResult> redeemPromoCode(
    String code, {
    String? userId,
    String? subscriptionQueueId,
    int? discountValueCents,
  }) async {
    try {
      final currentUserId = userId ?? _supabase.auth.currentUser?.id;
      if (currentUserId == null) {
        return PromoCodeRedemptionResult(
          success: false,
          errorMessage: 'User not authenticated',
        );
      }

      final response = await _supabase.rpc(
        'redeem_promo_code',
        params: {
          'p_code': code,
          'p_user_id': currentUserId,
          'p_subscription_queue_id': subscriptionQueueId,
          'p_discount_value_cents': discountValueCents,
        },
      );

      if (response == null || (response is List ? response.isEmpty : false)) {
        return PromoCodeRedemptionResult(
          success: false,
          errorMessage: 'Invalid response from server',
        );
      }

      final data = response is List ? response.first : response;

      return PromoCodeRedemptionResult(
        success: data['success'] == true,
        errorMessage: data['error_message'],
        usageId: data['usage_id'],
        message: data['message'],
      );
    } catch (e) {
      debugPrint('Error redeeming promo code: $e');
      return PromoCodeRedemptionResult(
        success: false,
        errorMessage: 'Promo code redemption failed',
      );
    }
  }

  /// Gets details about a promo code (for display purposes)
  Future<PromoCodeDetailsResult?> getPromoCodeDetails(String code) async {
    try {
      final response = await _supabase.rpc(
        'get_promo_code_details',
        params: {'p_code': code},
      );

      if (response == null || response.isEmpty) {
        return null;
      }

      final data = response is List ? response.first : response;

      return PromoCodeDetailsResult(
        code: data['code'],
        description: data['description'],
        codeType: data['code_type'],
        amount: data['amount'] as int?,
        upgradeTier: data['upgrade_tier'],
        campaignName: data['campaign_name'],
        validUntil: data['valid_until'] != null
            ? DateTime.parse(data['valid_until'] as String)
            : null,
        serverExpired: data['is_expired'] == true,
      );
    } catch (e) {
      debugPrint('Error getting promo code details: $e');
      return null;
    }
  }

  /// Generates a user-readable discount description
  static String generateDiscountDescription(
    String codeType, {
    int? amount,
    String? upgradeTier,
  }) {
    switch (codeType) {
      case 'discount_percentage':
        return '$amount% Off';
      case 'discount_fixed':
        final dollars = (amount ?? 0) / 100;
        return '\$$dollars Off';
      case 'free_days':
        final dayText = (amount ?? 1) == 1 ? 'day' : 'days';
        return '$amount $dayText Free';
      case 'tier_upgrade':
        return 'Upgrade to $upgradeTier';
      default:
        return 'Special Offer';
    }
  }

  /// Calculates the discount value in cents for a purchase amount
  static int calculateDiscount(
    String codeType,
    int purchaseAmountCents, {
    int? amount,
  }) {
    switch (codeType) {
      case 'discount_percentage':
        if (amount == null) return 0;
        return (purchaseAmountCents * amount) ~/ 100;
      case 'discount_fixed':
        return amount ?? 0;
      default:
        return 0;
    }
  }
}

/// Result class for promo code validation
class PromoCodeValidationResult {
  final bool valid;
  final String? errorMessage;
  final String? code;
  final String? codeId;
  final String? codeType;
  final int? amount;
  final String? upgradeTier;
  final int? maxUsesPerUser;
  final int? currentUserUses;
  final int? totalUses;
  final int? maxUses;

  PromoCodeValidationResult({
    required this.valid,
    this.errorMessage,
    this.code,
    this.codeId,
    this.codeType,
    this.amount,
    this.upgradeTier,
    this.maxUsesPerUser,
    this.currentUserUses,
    this.totalUses,
    this.maxUses,
  });

  bool get isNearLimit =>
      maxUsesPerUser != null &&
      currentUserUses != null &&
      currentUserUses! >= (maxUsesPerUser! - 1);

  int? get discountPercent {
    if (codeType == 'discount_percentage') {
      return amount;
    }
    return null;
  }

  int? get discountAmountCents {
    if (codeType == 'discount_fixed') {
      return amount;
    }
    return null;
  }

  int? get freeDays {
    if (codeType == 'free_days') {
      return amount;
    }
    return null;
  }

  String get discountDescription =>
      PromoCodeService.generateDiscountDescription(
        codeType ?? '',
        amount: amount,
        upgradeTier: upgradeTier,
      );
}

/// Result class for promo code redemption
class PromoCodeRedemptionResult {
  final bool success;
  final String? errorMessage;
  final String? usageId;
  final String? message;

  PromoCodeRedemptionResult({
    required this.success,
    this.errorMessage,
    this.usageId,
    this.message,
  });
}

/// Result class for promo code details
/// isExpired is trustable from the server (get_promo_code_details RPC returns server-time-based expiry).
class PromoCodeDetailsResult {
  final String code;
  final String? description;
  final String codeType;
  final int? amount;
  final String? upgradeTier;
  final String? campaignName;
  final DateTime? validUntil;
  final bool serverExpired; // Authoritative: determined by server clock

  PromoCodeDetailsResult({
    required this.code,
    this.description,
    required this.codeType,
    this.amount,
    this.upgradeTier,
    this.campaignName,
    this.validUntil,
    this.serverExpired = false,
  });

  bool get isExpired => serverExpired;

  int? get discountPercent {
    if (codeType == 'discount_percentage') {
      return amount;
    }
    return null;
  }

  int? get discountAmountCents {
    if (codeType == 'discount_fixed') {
      return amount;
    }
    return null;
  }

  int? get freeDays {
    if (codeType == 'free_days') {
      return amount;
    }
    return null;
  }

  String get daysUntilExpiry {
    if (validUntil == null) return 'No expiry';
    if (serverExpired) return 'Expired';
    final now = DateTime.now();
    final difference = validUntil!.difference(now).inDays;
    if (difference <= 0) return 'Today';
    return difference == 1 ? '1 day left' : '$difference days left';
  }
}
