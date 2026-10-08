import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/sponsored_ad.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/ad_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/supabase_reachability.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/offline_utils.dart';

// Cache for ad fetches to prevent rapid consecutive fetches
final Map<String, SponsoredAd?> _lastAdCache = <String, SponsoredAd?>{};
final Map<String, DateTime> _lastAdFetch = <String, DateTime>{};

// Dedup: track last eligibility reason per placement to suppress repeated identical logs
final Map<String, String?> _lastLoggedReason = <String, String?>{};

// Persisted cache keys
const String _adCacheKey = 'cached_ads';
const String _adFetchTimestampsKey = 'cached_ad_timestamps';

/// Load ads from persistent storage
Future<void> _loadAdCache() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final cachedJson = prefs.getString(_adCacheKey);
    if (cachedJson != null) {
      final Map<String, dynamic> cached = jsonDecode(cachedJson);
      cached.forEach((key, value) {
        if (value != null) {
          _lastAdCache[key] = SponsoredAd.fromJson(value);
        }
      });
      if (kDebugMode) {
        print(
          '[SponsoredAdProvider] Loaded ${_lastAdCache.length} ads from persistent cache',
        );
      }
    }
    final timestampsJson = prefs.getString(_adFetchTimestampsKey);
    if (timestampsJson != null) {
      final Map<String, dynamic> timestamps = jsonDecode(timestampsJson);
      timestamps.forEach((key, value) {
        if (value is String) {
          _lastAdFetch[key] = DateTime.parse(value);
        }
      });
      if (kDebugMode) {
        print(
          '[SponsoredAdProvider] Loaded ${_lastAdFetch.length} fetch timestamps from persistent cache',
        );
      }
    }
  } catch (e) {
    if (kDebugMode) {
      print('[SponsoredAdProvider] Error loading ad cache: $e');
    }
  }
}

/// Save ads and fetch timestamps to persistent storage
Future<void> _saveAdCache() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> toSave = {};
    _lastAdCache.forEach((key, ad) {
      if (ad != null) {
        toSave[key] = ad.toJson();
      }
    });
    await prefs.setString(_adCacheKey, jsonEncode(toSave));

    final Map<String, dynamic> timestampsToSave = {};
    _lastAdFetch.forEach((key, dt) {
      timestampsToSave[key] = dt.toIso8601String();
    });
    await prefs.setString(_adFetchTimestampsKey, jsonEncode(timestampsToSave));

    if (kDebugMode) {
      print(
        '[SponsoredAdProvider] Saved ${toSave.length} ads and ${timestampsToSave.length} timestamps to persistent cache',
      );
    }
  } catch (e) {
    if (kDebugMode) {
      print('[SponsoredAdProvider] Error saving ad cache: $e');
    }
  }
}

/// Initialize ad cache on app start
Future<void> initializeAdCache() async {
  await _loadAdCache();

  // Don't fetch ads here - the connectivity check might not have completed yet
  // Ads will be fetched when:
  // 1. Widgets request them (if online)
  // 2. The current screen's AdSlot refreshes when Supabase resumes
  if (kDebugMode) {
    final isPaused = shouldSkipSupabaseCalls();
    print(
      '[SponsoredAdProvider] Ad cache initialized. Supabase paused: $isPaused',
    );
  }
}

/// Clear ad cache for a specific placement or all placements
Future<void> clearAdCache({String? placement}) async {
  if (placement != null) {
    _lastAdCache.remove(placement);
    _lastAdFetch.remove(placement);
    if (kDebugMode) {
      print('[SponsoredAdProvider] Cleared cache for placement: $placement');
    }
  } else {
    _lastAdCache.clear();
    _lastAdFetch.clear();
    if (kDebugMode) {
      print('[SponsoredAdProvider] Cleared all ad caches');
    }
  }
  // Update persistent storage
  await _saveAdCache();
}

/// Set up connectivity listener to refresh ads when coming back online
void setupAdConnectivityListener() {
  bool? lastOnline;

  listenConnectivityChanged((_) async {
    try {
      // The event only says "something changed" — confirm with a real Supabase
      // round trip instead of trusting the platform transport result. Ads are
      // served from Supabase, so a working internet with a dead backend is
      // still offline for this purpose.
      final online =
          (await probeSupabaseReachability(
            log: (m) => print('[SponsoredAdProvider] $m'),
          )).isReachable;

      // If we're online now but weren't before, age the timestamps so ads
      // can be re-fetched once while the cache guard still works.
      if (online && lastOnline == false) {
        if (kDebugMode) {
          print(
            '[SponsoredAdProvider] Device came back online - aging fetch timestamps (cache preserved)',
          );
        }
        final aged = DateTime.now().subtract(const Duration(seconds: 60));
        for (final key in _lastAdFetch.keys) {
          _lastAdFetch[key] = aged;
        }
      }

      lastOnline = online;
    } catch (_) {
      // Ignore errors
    }
  });
}

final Provider<AdService> adServiceProvider = Provider<AdService>((ref) {
  // Set up connectivity listener on first access
  setupAdConnectivityListener();

  return AdService();
});

/// Notifier that provides a cache-busting key that changes periodically
/// This ensures ad providers refresh their data regularly
class AdRefreshNotifier extends Notifier<int> {
  @override
  int build() {
    // Start a timer that increments the counter every 30 seconds
    // This forces ad providers to refetch data periodically
    // Increased from 10s to 30s to reduce unnecessary fetches
    ref.onDispose(() {
      // Timer will be cleaned up automatically
    });

    // Use a Future to set up the periodic refresh
    Future.microtask(() {
      _startPeriodicRefresh();
    });

    return 0;
  }

  void _startPeriodicRefresh() {
    // Increment counter every 30 seconds to force cache invalidation
    Future.delayed(const Duration(seconds: 30), () {
      if (mounted) {
        state = state + 1;
        _startPeriodicRefresh(); // Schedule next refresh
      }
    });
  }

  bool get mounted {
    try {
      // Check if the notifier is still active
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Provider that provides a cache-busting key that changes periodically
final _adRefreshProvider = NotifierProvider<AdRefreshNotifier, int>(() {
  return AdRefreshNotifier();
});

/// Public alias so the external ad provider can share the same poll tick.
final externalAdPollProvider = _adRefreshProvider;

/// Bumps whenever the admin changes anything in the ad systems.
///
/// The admin app calls admin_touch_ad_config() after every ad write
/// (campaign save/toggle/delete, config changes, network toggles), which
/// updates the ads.config_version row in app_config. That row reaches this
/// provider through the app_config realtime stream. On change we hard-clear
/// all internal ad caches so the next fetch ignores the debounce/reuse
/// windows and the change is visible immediately.
class AdConfigEpochNotifier extends Notifier<int> {
  String? _lastVersion;
  int _counter = 0;

  @override
  int build() {
    final config = ref.watch(appConfigProvider);
    final version = config['ads.config_version'];

    if (_lastVersion == null) {
      // First build — adopt the current value without invalidating.
      _lastVersion = version;
    } else if (_lastVersion != version) {
      _lastVersion = version;
      _counter++;
      if (kDebugMode) {
        print(
          '[AdConfigEpoch] ad config changed (version=$version) - clearing ad caches',
        );
      }
      unawaited(clearAdCache());
      // The eligibility path reads config through AppConfigService, which has
      // its own 5-minute-TTL cache. Drop it and refresh so placement/tier/
      // pacing checks reflect the change immediately instead of up to 5
      // minutes later.
      appConfigService.clearCache();
      unawaited(
        appConfigService.refresh().catchError((Object e) {
          if (kDebugMode) {
            print('[AdConfigEpoch] AppConfigService refresh failed: $e');
          }
        }),
      );
    }
    return _counter;
  }
}

/// Counter that increments on every admin ad change (via realtime config).
final adConfigEpochProvider =
    NotifierProvider<AdConfigEpochNotifier, int>(AdConfigEpochNotifier.new);

/// Helper provider that creates a cache-busting key when config changes or on periodic refresh
/// This ensures ad providers invalidate when config changes OR periodically
final _adConfigKeyProvider = Provider<String>((ref) {
  final config = ref.watch(appConfigProvider);
  // Watch the refresh counter to trigger periodic invalidation
  final refreshCounter = ref.watch(_adRefreshProvider);
  // Bump on every admin ad change (campaign edits, toggles, config writes)
  final adEpoch = ref.watch(adConfigEpochProvider);

  // Create a simple hash of critical ad config values
  // When any of these change, the key changes and providers invalidate
  final familySafeOnly = config['ads.internal.family_safe_only'] ?? 'true';
  final adsEnabled = config['ads.internal.enabled'] ?? 'false';
  final sponsoredCardsEnabled =
      config['ads.internal.sponsored_cards_enabled'] ?? 'true';
  final allowedTiers =
      config['ads.internal.allowed_tiers'] ??
      '["free", "plus", "gold", "platinum"]';
  final allowedPlacements =
      config['ads.internal.allowed_placements'] ??
      '["home_inline", "matches_inline"]';

  return '$familySafeOnly|$adsEnabled|$sponsoredCardsEnabled|$allowedTiers|$allowedPlacements|$refreshCounter|$adEpoch';
});

final adEligibilityProvider = FutureProvider.family<AdEligibility, AdPlacement>(
  (ref, placement) async {
    // Watch the config key to invalidate when config changes
    final _ = ref.watch(_adConfigKeyProvider);
    final currentUser = Supabase.instance.client.auth.currentUser;
    if (currentUser == null) {
      return const AdEligibility(
        canShowSponsoredCard: false,
        reason: 'not_authenticated',
      );
    }

    final profile = await ref.watch(userProfileProvider(currentUser.id).future);
    final subscriptionTier = profile?.subscriptionTier ?? 'free';
    final eligibility = await ref
        .read(adServiceProvider)
        .getEligibility(
          userId: currentUser.id,
          subscriptionTier: subscriptionTier,
          placement: placement,
        );
    return eligibility;
  },
);

final sponsoredAdProvider = FutureProvider.family<SponsoredAd?, AdPlacement>((
  ref,
  placement,
) async {
  // Watch the config key to invalidate when config changes
  final _ = ref.watch(_adConfigKeyProvider);
  final locale = ref
      .watch(localizationProvider)
      .currentLocale
      .languageCode
      .trim();
  final placementKey = placement.value;

  // Watch connectivity state to react to offline/online changes
  final connectivityAsync = ref.watch(connectivityProvider);
  final isOnline = connectivityAsync.value ?? false;

  if (!isOnline || shouldSkipSupabaseCalls()) {
    final config = ref.read(appConfigProvider);
    final adsEnabled =
        (config['ads.internal.enabled'] ?? 'false').toLowerCase() == 'true';
    final sponsoredCardsEnabled =
        (config['ads.internal.sponsored_cards_enabled'] ?? 'true')
            .toLowerCase() ==
        'true';
    if (!adsEnabled || !sponsoredCardsEnabled) {
      return null;
    }

    // Always return cached ad if available when offline
    if (_lastAdCache.containsKey(placementKey)) {
      return _lastAdCache[placementKey];
    }
    // If no cached ad, try to load from persistent storage
    if (kDebugMode) {
      print(
        '[SponsoredAdProvider] ${placement.value}: no in-memory cache, loading from persistent storage',
      );
    }
    await _loadAdCache();
    if (_lastAdCache.containsKey(placementKey)) {
      if (kDebugMode) {
        print(
          '[SponsoredAdProvider] ${placement.value}: using ad from persistent cache',
        );
      }
      return _lastAdCache[placementKey];
    }
    if (kDebugMode) {
      print(
        '[SponsoredAdProvider] ${placement.value}: no cached ad available (offline)',
      );
    }
    return null;
  }

  // Only check eligibility when online
  final eligibility = await ref.watch(adEligibilityProvider(placement).future);
  if (!eligibility.canShowSponsoredCard) {
    final reason = eligibility.reason ?? 'unknown';
    if (kDebugMode && _lastLoggedReason[placement.value] != reason) {
      print(
        '[SponsoredAdProvider] ${placement.value}: skipped fetch, reason=$reason',
      );
      _lastLoggedReason[placement.value] = reason;
    }
    return null;
  }

  // Debounce: skip fetch if we've recently fetched this placement
  final now = DateTime.now();
  final lastFetch = _lastAdFetch[placementKey];

  if (lastFetch != null &&
      now.difference(lastFetch) < const Duration(seconds: 10)) {
    if (kDebugMode) {
      print(
        '[SponsoredAdProvider] ${placement.value}: using cached ad - debounce active',
      );
    }
    return _lastAdCache[placementKey];
  }

  // If we have a cached ad, avoid unnecessary re-fetches
  final cached = _lastAdCache[placementKey];
  if (cached != null &&
      (lastFetch == null ||
          now.difference(lastFetch) < const Duration(seconds: 60))) {
    if (kDebugMode) {
      print('[SponsoredAdProvider] ${placement.value}: reusing cached ad');
    }
    _lastAdFetch[placementKey] = now;
    return cached;
  }

  final ad = await ref
      .read(adServiceProvider)
      .fetchSponsoredAd(
        placement: placement,
        locale: locale.isEmpty ? 'en' : locale,
      );

  // Cache the result and timestamp
  _lastAdCache[placementKey] = ad;
  _lastAdFetch[placementKey] = now;

  // Save to persistent storage
  await _saveAdCache();

  if (kDebugMode) {
    print(
      '[SponsoredAdProvider] ${placement.value}: fetch result=${ad == null ? 'null' : ad.creativeId}',
    );
  }
  return ad;
});
