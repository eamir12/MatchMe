import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/offline_utils.dart';

// Cache for external ad units
final Map<String, AdUnit?> _externalAdCache = <String, AdUnit?>{};
final Map<String, DateTime> _lastExternalAdFetch = <String, DateTime>{};
const String _externalAdCacheKey = 'cached_external_ads';
const String _externalAdFetchTimestampsKey = 'cached_external_ad_timestamps';

/// Read cached external ad for a placement/platform key (e.g. `home_inline_web`).
AdUnit? peekCachedExternalAd(String cacheKey) => _externalAdCache[cacheKey];

DateTime? peekExternalAdFetchTime(String cacheKey) =>
    _lastExternalAdFetch[cacheKey];

void recordExternalAdCacheHit(String cacheKey) {
  _lastExternalAdFetch[cacheKey] = DateTime.now();
}

/// Model for external ad network configuration
class ExternalAdNetwork {
  const ExternalAdNetwork({
    required this.id,
    required this.provider,
    required this.displayName,
    required this.isEnabled,
    required this.priority,
    required this.config,
  });

  final String id;
  final String provider; // 'admob', 'facebook', 'applovin', 'unity'
  final String displayName;
  final bool isEnabled;
  final int priority;
  final Map<String, dynamic> config;

  factory ExternalAdNetwork.fromMap(Map<String, dynamic> data) {
    return ExternalAdNetwork(
      id: (data['id'] ?? '').toString(),
      provider: (data['provider'] ?? '').toString(),
      displayName: (data['display_name'] ?? '').toString(),
      isEnabled: data['is_enabled'] ?? false,
      priority: (data['priority'] ?? 100) as int,
      config: (data['config'] ?? {}) as Map<String, dynamic>,
    );
  }
}

/// Model for ad unit configuration
class AdUnit {
  const AdUnit({
    required this.id,
    required this.networkId,
    required this.placement,
    required this.platform,
    required this.adUnitId,
    required this.adFormat,
    required this.isActive,
    required this.priority,
  });

  final String id;
  final String networkId;
  final String placement;
  final String platform; // 'android', 'ios', 'web'
  final String adUnitId;
  final String adFormat; // 'banner', 'interstitial', 'rewarded', 'native'
  final bool isActive;
  final int priority;

  factory AdUnit.fromMap(Map<String, dynamic> data) {
    // SQL returns: ad_unit_id (UUID), ad_unit_id_external (AdMob ID)
    // Must use correct column names from get_external_ad_for_placement RPC
    final String uuid = (data['ad_unit_id'] ?? data['id'] ?? '').toString();
    final String unitId =
        (data['ad_unit_id_external'] ??
                data['external_ad_unit_id'] ??
                data['ad_unit_id'] ??
                '')
            .toString();
    return AdUnit(
      id: uuid,
      networkId: (data['network_id'] ?? '').toString(),
      placement: (data['placement'] ?? '').toString(),
      platform: (data['platform'] ?? '').toString(),
      adUnitId: unitId,
      adFormat: (data['ad_format'] ?? '').toString(),
      isActive: data['is_active'] ?? true,
      priority: (data['priority'] ?? 100) as int,
    );
  }

  /// Serialize to JSON for caching
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'networkId': networkId,
      'placement': placement,
      'platform': platform,
      'adUnitId': adUnitId,
      'adFormat': adFormat,
      'isActive': isActive,
      'priority': priority,
    };
  }

  /// Deserialize from JSON for caching
  factory AdUnit.fromJson(Map<String, dynamic> json) {
    return AdUnit(
      id: json['id'] as String,
      networkId: json['networkId'] as String,
      placement: json['placement'] as String,
      platform: json['platform'] as String,
      adUnitId: json['adUnitId'] as String,
      adFormat: json['adFormat'] as String,
      isActive: json['isActive'] as bool,
      priority: json['priority'] as int,
    );
  }
}

/// Model for user ad consent
class AdConsent {
  const AdConsent({
    required this.userId,
    required this.personalizedAds,
    required this.nonPersonalizedAds,
    required this.consentGivenAt,
    required this.consentVersion,
  });

  final String userId;
  final bool personalizedAds;
  final bool nonPersonalizedAds;
  final DateTime consentGivenAt;
  final String consentVersion;

  factory AdConsent.fromMap(Map<String, dynamic> data) {
    return AdConsent(
      userId: (data['user_id'] ?? '').toString(),
      personalizedAds: data['personalized_ads'] ?? false,
      nonPersonalizedAds: data['non_personalized_ads'] ?? true,
      consentGivenAt: data['consent_given_at'] != null
          ? DateTime.parse(data['consent_given_at'].toString())
          : DateTime.now(),
      consentVersion: (data['consent_version'] ?? '1.0').toString(),
    );
  }
}

/// Model for ad revenue event
class AdRevenueEvent {
  const AdRevenueEvent({
    required this.userId,
    required this.networkId,
    required this.adUnitId,
    required this.placement,
    required this.platform,
    required this.eventType,
    required this.revenueUsd,
    required this.adFormat,
    required this.createdAt,
  });

  final String userId;
  final String networkId;
  final String adUnitId;
  final String placement;
  final String platform;
  final String eventType; // 'impression', 'click', 'conversion'
  final double revenueUsd;
  final String adFormat;
  final DateTime createdAt;

  factory AdRevenueEvent.fromMap(Map<String, dynamic> data) {
    return AdRevenueEvent(
      userId: (data['user_id'] ?? '').toString(),
      networkId: (data['network_id'] ?? '').toString(),
      adUnitId: (data['ad_unit_id'] ?? '').toString(),
      placement: (data['placement'] ?? '').toString(),
      platform: (data['platform'] ?? '').toString(),
      eventType: (data['event_type'] ?? '').toString(),
      revenueUsd: double.tryParse(data['revenue_usd']?.toString() ?? '0') ?? 0,
      adFormat: (data['ad_format'] ?? '').toString(),
      createdAt: data['created_at'] != null
          ? DateTime.parse(data['created_at'].toString())
          : DateTime.now(),
    );
  }
}

/// Load external ad cache from persistent storage
Future<void> loadExternalAdCache() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final cacheJson = prefs.getString(_externalAdCacheKey);
    if (cacheJson != null) {
      final Map<String, dynamic> cacheData = jsonDecode(cacheJson);
      cacheData.forEach((key, value) {
        if (value != null) {
          _externalAdCache[key] = AdUnit.fromJson(
            value as Map<String, dynamic>,
          );
        }
      });
      if (kDebugMode) {
        print(
          '[ExternalAdService] Loaded ${_externalAdCache.length} ads from persistent cache',
        );
      }
    }
    final timestampsJson = prefs.getString(_externalAdFetchTimestampsKey);
    if (timestampsJson != null) {
      final Map<String, dynamic> timestamps = jsonDecode(timestampsJson);
      timestamps.forEach((key, value) {
        if (value is String) {
          _lastExternalAdFetch[key] = DateTime.parse(value);
        }
      });
    }
  } catch (e) {
    if (kDebugMode) {
      print('[ExternalAdService] Error loading ad cache: $e');
    }
  }
}

/// Save external ad cache to persistent storage
Future<void> _saveExternalAdCache() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> cacheData = {};
    _externalAdCache.forEach((key, value) {
      if (value != null) {
        cacheData[key] = value.toJson();
      }
    });
    await prefs.setString(_externalAdCacheKey, jsonEncode(cacheData));

    final Map<String, dynamic> timestampsToSave = {};
    _lastExternalAdFetch.forEach((key, dt) {
      timestampsToSave[key] = dt.toIso8601String();
    });
    await prefs.setString(
      _externalAdFetchTimestampsKey,
      jsonEncode(timestampsToSave),
    );

    if (kDebugMode) {
      print(
        '[ExternalAdService] Saved ${_externalAdCache.length} ads to persistent cache',
      );
    }
  } catch (e) {
    if (kDebugMode) {
      print('[ExternalAdService] Error saving ad cache: $e');
    }
  }
}

/// Initialize external ad cache on app start
Future<void> initializeExternalAdCache() async {
  await loadExternalAdCache();
  if (kDebugMode) {
    print('[ExternalAdService] External ad cache initialized');
  }
}

/// Get the external ad cache (for use by external_ad_provider)
Map<String, AdUnit?> getExternalAdCache() {
  return Map.from(_externalAdCache);
}

/// Service for managing external ad networks
class ExternalAdService {
  ExternalAdService({SupabaseClient? supabaseClient})
    : _supabase = supabaseClient ?? Supabase.instance.client;

  final SupabaseClient _supabase;

  /// Get external ad for a specific placement with mediation
  Future<AdUnit?> getExternalAdForPlacement({
    required String placement,
    required String platform,
  }) async {
    final cacheKey = '${placement}_$platform';

    // If offline, return cached ad immediately
    if (shouldSkipSupabaseCalls()) {
      if (_externalAdCache.containsKey(cacheKey)) {
        return _externalAdCache[cacheKey];
      }
      // If no cached ad, try to load from persistent storage
      if (kDebugMode) {
        print(
          '[ExternalAdService] $cacheKey: no in-memory cache, loading from persistent storage',
        );
      }
      await loadExternalAdCache();
      if (_externalAdCache.containsKey(cacheKey)) {
        if (kDebugMode) {
          print(
            '[ExternalAdService] $cacheKey: using ad from persistent cache',
          );
        }
        return _externalAdCache[cacheKey];
      }
      if (kDebugMode) {
        print(
          '[ExternalAdService] $cacheKey: no cached ad available (offline)',
        );
      }
      return null;
    }

    try {
      print(
        '📡 [ExternalAdService] Fetching ad for placement=$placement, platform=$platform',
      );

      final response = await _supabase.rpc(
        'get_external_ad_for_placement',
        params: {'p_placement': placement, 'p_platform': platform},
      );

      print('📡 [ExternalAdService] RPC response: $response');

      AdUnit? ad;
      if (response is List && response.isNotEmpty) {
        print('✓ [ExternalAdService] Found ad in list response');
        ad = AdUnit.fromMap(Map<String, dynamic>.from(response.first));
      } else if (response is Map<String, dynamic> && response.isNotEmpty) {
        print('✓ [ExternalAdService] Found ad in map response');
        ad = AdUnit.fromMap(response);
      } else {
        print('⚠️ [ExternalAdService] No ad found for placement=$placement');
        return null;
      }

      // Cache the ad
      _externalAdCache[cacheKey] = ad;
      _lastExternalAdFetch[cacheKey] = DateTime.now();
      await _saveExternalAdCache();

      return ad;
    } catch (e) {
      print('⚠️ [ExternalAdService] Failed to load external ad: $e');
      return null;
    }
  }

  /// Record an external ad impression
  Future<bool> recordImpression({
    required String networkId,
    required String adUnitId,
    required String placement,
    required String platform,
    required String adFormat,
  }) async {
    if (shouldSkipSupabaseCalls()) return false;

    try {
      await _supabase.rpc(
        'record_external_ad_impression',
        params: {
          'p_network_id': networkId,
          'p_ad_unit_id': adUnitId,
          'p_placement': placement,
          'p_platform': platform,
          'p_ad_format': adFormat,
        },
      );
      return true;
    } catch (e) {
      print('⚠️ [ExternalAdService] Failed to record impression: $e');
      return false;
    }
  }

  /// Record an external ad click
  Future<bool> recordClick({
    required String networkId,
    required String adUnitId,
    required String placement,
    required String platform,
    required String adFormat,
  }) async {
    if (shouldSkipSupabaseCalls()) return false;

    try {
      await _supabase.rpc(
        'record_external_ad_click',
        params: {
          'p_network_id': networkId,
          'p_ad_unit_id': adUnitId,
          'p_placement': placement,
          'p_platform': platform,
          'p_ad_format': adFormat,
        },
      );
      return true;
    } catch (e) {
      print('⚠️ [ExternalAdService] Failed to record click: $e');
      return false;
    }
  }

  /// Get user's ad consent preferences
  Future<AdConsent?> getUserAdConsent(String userId) async {
    if (shouldSkipSupabaseCalls()) return null;

    try {
      final response = await _supabase.rpc(
        'get_user_ad_consent',
        params: {'p_user_id': userId},
      );

      if (response is List && response.isNotEmpty) {
        return AdConsent.fromMap(Map<String, dynamic>.from(response.first));
      }

      if (response is Map<String, dynamic> && response.isNotEmpty) {
        return AdConsent.fromMap(response);
      }

      return null;
    } catch (e) {
      print('⚠️ [ExternalAdService] Failed to get user consent: $e');
      return null;
    }
  }

  /// Update user's ad consent preferences
  Future<AdConsent?> updateUserAdConsent({
    required bool personalizedAds,
    required bool nonPersonalizedAds,
  }) async {
    if (shouldSkipSupabaseCalls()) return null;

    try {
      final response = await _supabase.rpc(
        'update_user_ad_consent',
        params: {
          'p_personalized_ads': personalizedAds,
          'p_non_personalized_ads': nonPersonalizedAds,
        },
      );

      if (response is List && response.isNotEmpty) {
        return AdConsent.fromMap(Map<String, dynamic>.from(response.first));
      }

      if (response is Map<String, dynamic> && response.isNotEmpty) {
        return AdConsent.fromMap(response);
      }

      return null;
    } catch (e) {
      print('⚠️ [ExternalAdService] Failed to update user consent: $e');
      return null;
    }
  }

  /// Get ad network analytics for a date range
  Future<List<Map<String, dynamic>>> getAdNetworkAnalytics({
    required String networkId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    if (shouldSkipSupabaseCalls()) return [];

    try {
      final response = await _supabase.rpc(
        'get_ad_network_analytics',
        params: {
          'p_network_id': networkId,
          'p_start_date': startDate.toIso8601String().split('T')[0],
          'p_end_date': endDate.toIso8601String().split('T')[0],
        },
      );

      {
        return List<Map<String, dynamic>>.from(
          response.map((item) => Map<String, dynamic>.from(item as Map)),
        );
      }
    } catch (e) {
      print('⚠️ [ExternalAdService] Failed to get analytics: $e');
      return [];
    }
  }

  /// Get all enabled ad networks (admin only)
  Future<List<ExternalAdNetwork>> getEnabledNetworks() async {
    try {
      final response = await _supabase
          .from('ad_networks')
          .select()
          .eq('is_enabled', true)
          .order('priority', ascending: true);

      {
        return response
            .map(
              (item) => ExternalAdNetwork.fromMap(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList();
      }
    } catch (e) {
      print('⚠️ [ExternalAdService] Failed to get networks: $e');
      return [];
    }
  }

  /// Get all ad units for a network (admin only)
  Future<List<AdUnit>> getAdUnitsForNetwork(String networkId) async {
    try {
      final response = await _supabase
          .from('ad_units')
          .select()
          .eq('network_id', networkId)
          .eq('is_active', true)
          .order('priority', ascending: true);

      {
        return response
            .map(
              (item) => AdUnit.fromMap(Map<String, dynamic>.from(item as Map)),
            )
            .toList();
      }
    } catch (e) {
      print('⚠️ [ExternalAdService] Failed to get ad units: $e');
      return [];
    }
  }
}
