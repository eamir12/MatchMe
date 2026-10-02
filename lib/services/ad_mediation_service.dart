import 'package:matchme/services/external_ad_service.dart';

/// Service for managing ad mediation across multiple networks
///
/// Mediation logic:
/// 1. Try highest-priority network first
/// 2. Fall back to next network if no fill
/// 3. Show internal sponsored ads if no external fill
/// 4. Track fill rates and optimize priority
class AdMediationService {
  AdMediationService({required ExternalAdService externalAdService})
    : _externalAdService = externalAdService;

  final ExternalAdService _externalAdService;

  /// Get best ad for placement using mediation logic
  ///
  /// Returns the ad unit with highest priority that has fill
  Future<AdUnit?> getBestAdForPlacement({
    required String placement,
    required String platform,
  }) async {
    try {
      // Try to get external ad with mediation
      final externalAd = await _externalAdService.getExternalAdForPlacement(
        placement: placement,
        platform: platform,
      );

      if (externalAd != null) {
        print(
          '✓ [AdMediationService] Found external ad: ${externalAd.adFormat} from ${externalAd.networkId}',
        );
        return externalAd;
      }

      print(
        '⚠️ [AdMediationService] No external ad fill for placement: $placement',
      );
      return null;
    } catch (e) {
      print('⚠️ [AdMediationService] Mediation error: $e');
      return null;
    }
  }

  /// Record impression for mediated ad
  Future<bool> recordImpressionForAd(AdUnit ad) async {
    try {
      final success = await _externalAdService.recordImpression(
        networkId: ad.networkId,
        adUnitId: ad.id,
        placement: ad.placement,
        platform: ad.platform,
        adFormat: ad.adFormat,
      );

      if (success) {
        print('✓ [AdMediationService] Recorded impression for ${ad.adFormat}');
      }

      return success;
    } catch (e) {
      print('⚠️ [AdMediationService] Failed to record impression: $e');
      return false;
    }
  }

  /// Record click for mediated ad
  Future<bool> recordClickForAd(AdUnit ad) async {
    try {
      final success = await _externalAdService.recordClick(
        networkId: ad.networkId,
        adUnitId: ad.id,
        placement: ad.placement,
        platform: ad.platform,
        adFormat: ad.adFormat,
      );

      if (success) {
        print('✓ [AdMediationService] Recorded click for ${ad.adFormat}');
      }

      return success;
    } catch (e) {
      print('⚠️ [AdMediationService] Failed to record click: $e');
      return false;
    }
  }

  /// Get mediation strategy info
  ///
  /// Returns information about current mediation setup
  Future<Map<String, dynamic>> getMediationInfo() async {
    try {
      final networks = await _externalAdService.getEnabledNetworks();

      return {
        'enabled_networks': networks.length,
        'networks': networks
            .map(
              (n) => {
                'provider': n.provider,
                'priority': n.priority,
                'enabled': n.isEnabled,
              },
            )
            .toList(),
        'mediation_enabled': networks.isNotEmpty,
      };
    } catch (e) {
      print('⚠️ [AdMediationService] Failed to get mediation info: $e');
      return {
        'enabled_networks': 0,
        'networks': [],
        'mediation_enabled': false,
      };
    }
  }
}
