import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/services/ad_consent_service.dart';
import 'package:matchme/services/ad_platform_support.dart';
import 'package:matchme/services/ad_mediation_service.dart';
import 'package:matchme/services/ad_revenue_service.dart';
import 'package:matchme/services/admob_service.dart';
import 'package:matchme/services/external_ad_service.dart';
import 'package:matchme/services/mobile_ad_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/utils/offline_utils.dart';

final externalAdsRealtimeProvider = Provider<void>((ref) {
  final supabase = Supabase.instance.client;
  RealtimeChannel? adUnitsChannel;
  RealtimeChannel? adNetworksChannel;

  void subscribe() {
    SupabaseRealtimeManager.instance.register('ad_units_changes', () {
      adUnitsChannel = supabase
          .channel('ad_units_changes')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'ad_units',
            callback: (_) {
              ref.invalidate(externalAdProvider);
            },
          )
          .subscribe();
      return adUnitsChannel!;
    });

    SupabaseRealtimeManager.instance.register('ad_networks_changes', () {
      adNetworksChannel = supabase
          .channel('ad_networks_changes')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'ad_networks',
            callback: (_) {
              ref.invalidate(externalAdProvider);
            },
          )
          .subscribe();
      return adNetworksChannel!;
    });
  }

  subscribe();

  ref.onDispose(() {
    SupabaseRealtimeManager.instance.unregister('ad_units_changes');
    SupabaseRealtimeManager.instance.unregister('ad_networks_changes');
  });
});

/// Provider for ExternalAdService
final externalAdServiceProvider = Provider<ExternalAdService>((ref) {
  return ExternalAdService();
});

/// Provider for AdMobService
final adMobServiceProvider = Provider<AdMobService>((ref) {
  return AdMobService();
});

/// Provider for MobileAdService
final mobileAdServiceProvider = Provider<MobileAdService>((ref) {
  return MobileAdService();
});

/// Provider for AdMediationService
final adMediationServiceProvider = Provider<AdMediationService>((ref) {
  final externalAdService = ref.watch(externalAdServiceProvider);
  return AdMediationService(externalAdService: externalAdService);
});

/// Provider for AdRevenueService
final adRevenueServiceProvider = Provider<AdRevenueService>((ref) {
  return AdRevenueService();
});

/// Provider for AdConsentService
final adConsentServiceProvider = Provider<AdConsentService>((ref) {
  final externalAdService = ref.watch(externalAdServiceProvider);
  return AdConsentService(externalAdService: externalAdService);
});

/// Narrow config key so unrelated app_config changes do not refetch every placement.
final _externalAdConfigKeyProvider = Provider<String>((ref) {
  final config = ref.watch(appConfigProvider);
  final enabled = config['ads.external.enabled'] ?? 'false';
  final placements = config['ads.external.allowed_placements'] ?? '[]';
  final tiers = config['ads.external.allowed_tiers'] ?? '[]';
  final platforms = config['ads.external.allowed_platforms'] ?? '[]';
  return '$enabled|$placements|$tiers|$platforms';
});

/// Provider for getting external ad for a placement.
/// Mirrors [sponsoredAdProvider] debounce/cache so revisiting a tab does not refetch.
final externalAdProvider = FutureProvider.family<AdUnit?, String>((
  ref,
  placement,
) async {
  final _ = ref.watch(_externalAdConfigKeyProvider);

  // No ad SDK on Windows/macOS/Linux (google_mobile_ads implements Android, iOS
  // and web only). Skip the round trip rather than retrieving creatives this
  // platform can never render - the backend will happily answer a 'web' request
  // from a desktop build, which is how the previous behaviour looked like ads
  // were "loading" forever while nothing could ever appear.
  if (!isAdRenderSupported) {
    logAdPlatformSupportOnce();
    return null;
  }

  final connectivityAsync = ref.watch(connectivityProvider);
  final isOnline = connectivityAsync.value ?? false;

  final platform = _currentPlatformKey();
  final cacheKey = '${placement}_$platform';
  final mediationService = ref.watch(adMediationServiceProvider);

  Future<AdUnit?> serveFromPersistentCache() async {
    if (peekCachedExternalAd(cacheKey) != null) {
      return peekCachedExternalAd(cacheKey);
    }
    await loadExternalAdCache();
    return peekCachedExternalAd(cacheKey);
  }

  if (!isOnline || shouldSkipSupabaseCalls()) {
    final config = ref.read(appConfigProvider);
    final adsEnabled =
        (config['ads.external.enabled'] ?? 'false').toLowerCase() == 'true';
    if (!adsEnabled) {
      return null;
    }

    if (kDebugMode) {
      print(
        '[ExternalAdProvider] $cacheKey: offline - attempting to serve from cache',
      );
    }
    return serveFromPersistentCache();
  }

  final now = DateTime.now();
  final lastFetch = peekExternalAdFetchTime(cacheKey);

  if (lastFetch != null &&
      now.difference(lastFetch) < const Duration(seconds: 10)) {
    final cached = peekCachedExternalAd(cacheKey);
    if (cached != null) {
      if (kDebugMode) {
        print(
          '[ExternalAdProvider] $cacheKey: using cached ad - debounce active',
        );
      }
      return cached;
    }
  }

  final cached = peekCachedExternalAd(cacheKey);
  if (cached != null &&
      (lastFetch == null ||
          now.difference(lastFetch) < const Duration(seconds: 60))) {
    if (kDebugMode) {
      print('[ExternalAdProvider] $cacheKey: reusing cached ad');
    }
    recordExternalAdCacheHit(cacheKey);
    return cached;
  }

  final ad = await mediationService.getBestAdForPlacement(
    placement: placement,
    platform: platform,
  );

  if (ad == null) {
    // Keep last known unit when mediation has no fill (same as internal ads).
    return peekCachedExternalAd(cacheKey) ?? await serveFromPersistentCache();
  }

  if (kDebugMode) {
    print('[ExternalAdProvider] $cacheKey: fetch result=${ad.adUnitId}');
  }
  return ad;
});

/// Provider for user ad consent
final userAdConsentProvider = FutureProvider.family<AdConsent?, String>((
  ref,
  userId,
) async {
  final consentService = ref.watch(adConsentServiceProvider);
  return consentService.getUserConsent(userId);
});

/// Helper function to get current platform
///
/// Delegates to [adPlatformKey] so the banner, interstitial and rewarded paths
/// can never disagree about which platform they are fetching for.
String _currentPlatformKey() => adPlatformKey();
