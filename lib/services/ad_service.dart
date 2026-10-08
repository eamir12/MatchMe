import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:matchme/models/sponsored_ad.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AdService {
  AdService({SupabaseClient? supabaseClient, AppConfigService? configService})
    : _supabase = supabaseClient ?? Supabase.instance.client,
      _configService = configService ?? appConfigService;

  final SupabaseClient _supabase;
  final AppConfigService _configService;

  static final DateTime _sessionStartedAt = DateTime.now();
  static DateTime? _lastImpressionAt;
  static int _sessionImpressionCount = 0;

  Future<AdEligibility> getEligibility({
    required String userId,
    required String subscriptionTier,
    required AdPlacement placement,
  }) async {
    final adsEnabled = await _configService.areAdsEnabled();
    if (!adsEnabled) {
      return const AdEligibility(
        canShowSponsoredCard: false,
        reason: 'ads_disabled',
      );
    }

    final allowedPlacements = await _configService.getAdAllowedPlacements();
    if (!allowedPlacements.contains(placement.value)) {
      return const AdEligibility(
        canShowSponsoredCard: false,
        reason: 'placement_disabled',
      );
    }

    final allowedTiers = await _configService.getAdAllowedTiers();
    final normalizedTier = subscriptionTier.trim().toLowerCase();
    if (userId.trim().isEmpty || !allowedTiers.contains(normalizedTier)) {
      return const AdEligibility(
        canShowSponsoredCard: false,
        reason: 'tier_not_allowed',
      );
    }

    final firstImpressionDelay = await _configService
        .getAdFirstImpressionDelay();
    if (DateTime.now().difference(_sessionStartedAt) < firstImpressionDelay) {
      return const AdEligibility(
        canShowSponsoredCard: false,
        reason: 'first_impression_delay',
      );
    }

    final maxPerSession = await _configService.getAdMaxImpressionsPerSession();
    if (maxPerSession > 0 && _sessionImpressionCount >= maxPerSession) {
      return const AdEligibility(
        canShowSponsoredCard: false,
        reason: 'session_cap_reached',
      );
    }

    final minInterval = await _configService.getAdMinInterval();
    if (_lastImpressionAt != null &&
        DateTime.now().difference(_lastImpressionAt!) < minInterval) {
      return const AdEligibility(
        canShowSponsoredCard: false,
        reason: 'pacing_active',
      );
    }

    final sponsoredCardsEnabled = await _configService
        .areSponsoredCardsEnabled();

    return AdEligibility(canShowSponsoredCard: sponsoredCardsEnabled);
  }

  Future<SponsoredAd?> fetchSponsoredAd({
    required AdPlacement placement,
    required String locale,
  }) async {
    try {
      final response = await _supabase.rpc(
        'get_sponsored_ad_for_placement',
        params: {
          'p_placement': placement.value,
          'p_locale': locale,
          'p_platform': currentPlatformKey(),
        },
      );

      if (response is List && response.isNotEmpty) {
        return SponsoredAd.fromMap(Map<String, dynamic>.from(response.first));
      }

      if (response is Map<String, dynamic> && response.isNotEmpty) {
        return SponsoredAd.fromMap(response);
      }

      if (kDebugMode) {
        // An empty result is ambiguous: it can mean "no matching campaigns",
        // or that every creative is scoped to a different platform. The RPC
        // only returns creatives whose platform is 'all' or matches exactly,
        // so a creative created as 'web' is invisible on desktop with no
        // error anywhere.
        print(
          '[AdService] no internal ad for ${placement.value} '
          '(locale=$locale, platform=${currentPlatformKey()}). Creatives need '
          "ad_creatives.platform = 'all' or '${currentPlatformKey()}'.",
        );
      }
      return null;
    } catch (e) {
      // Previously swallowed entirely, which made a missing RPC, a signature
      // mismatch or a permissions failure look identical to "no campaigns".
      if (kDebugMode) {
        print(
          '[AdService] internal ad fetch failed for ${placement.value}: $e',
        );
      }
      return null;
    }
  }

  Future<void> recordImpression(SponsoredAd ad) async {
    try {
      await _supabase.rpc(
        'record_ad_impression',
        params: {
          'p_campaign_id': ad.campaignId,
          'p_creative_id': ad.creativeId,
          'p_placement': ad.placement,
          'p_platform': currentPlatformKey(),
          'p_locale': currentLocaleCode(),
        },
      );
      _sessionImpressionCount += 1;
      _lastImpressionAt = DateTime.now();
    } catch (e) {
      // Never fully silent: a permissions failure here means campaign caps
      // and pacing never engage and the same ad is re-served every interval.
      if (kDebugMode) {
        print('[AdService] record_ad_impression failed for ${ad.campaignId}: $e');
      }
    }
  }

  Future<void> recordClick(SponsoredAd ad) async {
    try {
      await _supabase.rpc(
        'record_ad_click',
        params: {
          'p_campaign_id': ad.campaignId,
          'p_creative_id': ad.creativeId,
          'p_placement': ad.placement,
          'p_platform': currentPlatformKey(),
          'p_locale': currentLocaleCode(),
          'p_destination_url': ad.destinationUrl,
        },
      );
    } catch (e) {
      if (kDebugMode) {
        print('[AdService] record_ad_click failed for ${ad.campaignId}: $e');
      }
    }
  }

  Future<bool> reportAd(
    SponsoredAd ad, {
    String reason = 'user_reported',
    String? details,
  }) async {
    try {
      await _supabase.rpc(
        'report_ad',
        params: {
          'p_campaign_id': ad.campaignId,
          'p_creative_id': ad.creativeId,
          'p_placement': ad.placement,
          'p_reason': reason,
          'p_details': details,
        },
      );
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('[AdService] report_ad failed: $e');
      }
      return false;
    }
  }

  String currentPlatformKey() {
    if (kIsWeb) {
      return 'web';
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'linux';
    }
  }

  String currentLocaleCode() {
    final code = WidgetsBinding.instance.platformDispatcher.locale.languageCode
        .trim();
    return code.isEmpty ? 'en' : code.toLowerCase();
  }
}
