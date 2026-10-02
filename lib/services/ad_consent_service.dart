import 'package:matchme/services/external_ad_service.dart';

/// Service for managing user ad consent and privacy preferences
class AdConsentService {
  AdConsentService({required ExternalAdService externalAdService})
    : _externalAdService = externalAdService;

  final ExternalAdService _externalAdService;

  /// Get user's current ad consent preferences
  Future<AdConsent?> getUserConsent(String userId) async {
    try {
      final consent = await _externalAdService.getUserAdConsent(userId);
      return consent;
    } catch (e) {
      print('⚠️ [AdConsentService] Failed to get user consent: $e');
      return null;
    }
  }

  /// Update user's ad consent preferences
  Future<AdConsent?> updateUserConsent({
    required bool personalizedAds,
    required bool nonPersonalizedAds,
  }) async {
    try {
      // At least one option must be enabled
      if (!personalizedAds && !nonPersonalizedAds) {
        print(
          '⚠️ [AdConsentService] At least one consent option must be enabled',
        );
        return null;
      }

      final consent = await _externalAdService.updateUserAdConsent(
        personalizedAds: personalizedAds,
        nonPersonalizedAds: nonPersonalizedAds,
      );

      if (consent != null) {
        print(
          '✓ [AdConsentService] User consent updated: personalized=$personalizedAds, non_personalized=$nonPersonalizedAds',
        );
      }

      return consent;
    } catch (e) {
      print('⚠️ [AdConsentService] Failed to update user consent: $e');
      return null;
    }
  }

  /// Check if user has given consent
  Future<bool> hasUserGivenConsent(String userId) async {
    try {
      final consent = await getUserConsent(userId);
      return consent != null;
    } catch (e) {
      print('⚠️ [AdConsentService] Failed to check consent status: $e');
      return false;
    }
  }

  /// Check if user allows personalized ads
  Future<bool> allowsPersonalizedAds(String userId) async {
    try {
      final consent = await getUserConsent(userId);
      return consent?.personalizedAds ?? false;
    } catch (e) {
      print('⚠️ [AdConsentService] Failed to check personalized ads: $e');
      return false;
    }
  }

  /// Check if user allows non-personalized ads
  Future<bool> allowsNonPersonalizedAds(String userId) async {
    try {
      final consent = await getUserConsent(userId);
      return consent?.nonPersonalizedAds ?? true;
    } catch (e) {
      print('⚠️ [AdConsentService] Failed to check non-personalized ads: $e');
      return true;
    }
  }

  /// Opt in to personalized ads
  Future<bool> optInToPersonalizedAds() async {
    try {
      final result = await updateUserConsent(
        personalizedAds: true,
        nonPersonalizedAds: true,
      );
      return result != null;
    } catch (e) {
      print('⚠️ [AdConsentService] Failed to opt in to personalized ads: $e');
      return false;
    }
  }

  /// Opt out of personalized ads (keep non-personalized)
  Future<bool> optOutOfPersonalizedAds() async {
    try {
      final result = await updateUserConsent(
        personalizedAds: false,
        nonPersonalizedAds: true,
      );
      return result != null;
    } catch (e) {
      print('⚠️ [AdConsentService] Failed to opt out of personalized ads: $e');
      return false;
    }
  }

  /// Opt out of all ads
  Future<bool> optOutOfAllAds() async {
    try {
      final result = await updateUserConsent(
        personalizedAds: false,
        nonPersonalizedAds: false,
      );
      return result != null;
    } catch (e) {
      print('⚠️ [AdConsentService] Failed to opt out of all ads: $e');
      return false;
    }
  }

  /// Get consent status summary
  Future<Map<String, dynamic>> getConsentSummary(String userId) async {
    try {
      final consent = await getUserConsent(userId);

      if (consent == null) {
        return {
          'has_consented': false,
          'personalized_ads': false,
          'non_personalized_ads': false,
          'consent_version': '1.0',
        };
      }

      return {
        'has_consented': true,
        'personalized_ads': consent.personalizedAds,
        'non_personalized_ads': consent.nonPersonalizedAds,
        'consent_version': consent.consentVersion,
        'consent_given_at': consent.consentGivenAt.toIso8601String(),
      };
    } catch (e) {
      print('⚠️ [AdConsentService] Failed to get consent summary: $e');
      return {
        'has_consented': false,
        'personalized_ads': false,
        'non_personalized_ads': false,
        'consent_version': '1.0',
      };
    }
  }

  /// Validate consent choices
  ///
  /// Returns error message if invalid, null if valid
  String? validateConsentChoices({
    required bool personalizedAds,
    required bool nonPersonalizedAds,
  }) {
    if (!personalizedAds && !nonPersonalizedAds) {
      return 'At least one consent option must be selected';
    }
    return null;
  }
}
