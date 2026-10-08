// lib/services/app_config_service.dart
// Service for fetching and caching application configuration from the app_config table

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:matchme/services/public_reference_data_service.dart';
import 'package:matchme/web_imports.dart' as html;
import 'package:matchme/utils/offline_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _appConfigCacheKey = 'cached_app_config';

class PasskeysRuntimeConfig {
  const PasskeysRuntimeConfig({
    required this.relyingPartyId,
    required this.serverBaseUrl,
  });

  final String relyingPartyId;
  final String serverBaseUrl;

  Uri? get serverBaseUri => Uri.tryParse(serverBaseUrl);

  bool get hasRequiredFields =>
      relyingPartyId.trim().isNotEmpty && serverBaseUrl.trim().isNotEmpty;

  bool get hasValidHttpsServerBaseUrl {
    final uri = serverBaseUri;
    return uri != null &&
        uri.isAbsolute &&
        uri.scheme == 'https' &&
        uri.host.trim().isNotEmpty;
  }

  bool get hasSupportedRelyingPartyIdFormat {
    final normalizedRelyingPartyId = relyingPartyId.trim().toLowerCase();
    if (normalizedRelyingPartyId.isEmpty) {
      return false;
    }

    // Allow localhost, android, and package names / domains.
    if (normalizedRelyingPartyId == 'localhost' ||
        normalizedRelyingPartyId == 'android' ||
        normalizedRelyingPartyId.contains('.')) {
      return true;
    }

    return false;
  }

  bool isCompatibleWithWebHost(String currentHost) {
    final normalizedCurrentHost = currentHost.trim().toLowerCase();
    final normalizedRelyingPartyId = relyingPartyId.trim().toLowerCase();
    if (normalizedCurrentHost.isEmpty || normalizedRelyingPartyId.isEmpty) {
      return false;
    }

    if (normalizedRelyingPartyId == 'localhost') {
      return normalizedCurrentHost == 'localhost';
    }

    return normalizedCurrentHost == normalizedRelyingPartyId ||
        normalizedCurrentHost.endsWith('.$normalizedRelyingPartyId');
  }

  bool get isValid =>
      hasRequiredFields &&
      hasValidHttpsServerBaseUrl &&
      hasSupportedRelyingPartyIdFormat;
}

/// Centralized service for accessing application configuration
/// Caches config values for performance and provides type-safe access
class AppConfigService {
  static final AppConfigService _instance = AppConfigService._internal();
  factory AppConfigService() => _instance;
  AppConfigService._internal();

  // Cache for config values
  final Map<String, dynamic> _configCache = {};
  DateTime? _lastFetchTime;
  DateTime? _lastTransientFailureAt;

  // Cache duration: refresh every 5 minutes
  static const Duration _cacheDuration = Duration(minutes: 5);
  static const Duration _transientRetryCooldown = Duration(seconds: 30);

  // Loading state
  bool _isLoading = false;
  bool _hasInitialized = false;
  bool _hasLoadedPersistentCache = false;
  Completer<void>? _loadCompleter;

  /// Initialize and load all config from database
  /// Call this once at app startup
  Future<void> initialize() async {
    await _loadPersistentCache();

    if (_isLoading) {
      // If already loading, wait for that operation to complete
      await _loadCompleter?.future;
      return;
    }

    final hasCachedConfig = _configCache.isNotEmpty;
    final withinTransientRetryCooldown =
        _configCache.isEmpty &&
        _lastTransientFailureAt != null &&
        DateTime.now().difference(_lastTransientFailureAt!) <
            _transientRetryCooldown;

    if (_hasInitialized && hasCachedConfig && !_shouldRefreshCache()) {
      return;
    }

    if (_hasInitialized && withinTransientRetryCooldown) {
      return;
    }

    _isLoading = true;
    _loadCompleter = Completer<void>();

    try {
      await _loadAllConfig();
      _lastTransientFailureAt = null;
      _hasInitialized = true;
      _loadCompleter!.complete();
    } catch (e) {
      final isTransient = _isTransientNetworkError(e);
      if (isTransient) {
        _lastTransientFailureAt = DateTime.now();
        _hasInitialized = true;
      }
      _loadCompleter!.complete();
    } finally {
      _isLoading = false;
    }
  }

  Future<void> _loadPersistentCache() async {
    if (_hasLoadedPersistentCache) return;
    _hasLoadedPersistentCache = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString(_appConfigCacheKey);
      if (cachedJson == null) return;

      final decoded = jsonDecode(cachedJson);
      if (decoded is Map<String, dynamic>) {
        _configCache.addAll(decoded);
      }
    } catch (_) {
      // A corrupt or unavailable cache should not prevent startup.
    }
  }

  /// Load all configuration from database
  Future<void> _loadAllConfig() async {
    try {
      // Skip fetch if Supabase communication is paused
      if (shouldSkipSupabaseCalls()) {
        return;
      }

      final response = await publicReferenceDataService
          .fetchAppConfigRows()
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw TimeoutException(
                'AppConfig fetch timeout after 10 seconds',
              );
            },
          );

      _configCache.clear();
      for (final row in response) {
        final key = row['config_key'] as String;
        final value = row['config_value'];

        // Store value as-is; it's already a string from the database
        _configCache[key] = value;
      }
      _lastFetchTime = DateTime.now();
      // Persist to local storage (memory + disk) for instant next startup.
      unawaited(_savePersistentCache());
    } catch (e) {
      // Don't rethrow - allow graceful offline fallback to cached/default config
    }
  }

  /// Persist the in-memory config to local storage (fire-and-forget).
  Future<void> _savePersistentCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_appConfigCacheKey, jsonEncode(_configCache));
    } catch (_) {}
  }

  /// Check if cache needs refresh
  bool _shouldRefreshCache() {
    if (_lastFetchTime == null) return true;
    return DateTime.now().difference(_lastFetchTime!) > _cacheDuration;
  }

  /// Refresh cache if needed
  Future<void> _ensureLoaded() async {
    await _loadPersistentCache();
    if (_configCache.isEmpty &&
        _lastTransientFailureAt != null &&
        DateTime.now().difference(_lastTransientFailureAt!) <
            _transientRetryCooldown) {
      return;
    }
    if (_configCache.isEmpty || _shouldRefreshCache()) {
      await initialize();
    }
  }

  bool _isTransientNetworkError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('socketexception') ||
        text.contains('clientexception') ||
        text.contains('connection abort') ||
        text.contains('connection reset') ||
        text.contains('timed out') ||
        text.contains('failed host lookup') ||
        text.contains('network is unreachable');
  }

  /// Get a string value
  Future<String> getString(String key, {String defaultValue = ''}) async {
    await _ensureLoaded();
    final value = _configCache[key];
    if (value == null) {
      return defaultValue;
    }
    // Remove quotes if present (for JSON string values)
    final strValue = value.toString();
    if (strValue.startsWith('"') && strValue.endsWith('"')) {
      return strValue.substring(1, strValue.length - 1);
    }
    return strValue;
  }

  /// Get an integer value
  Future<int> getInt(String key, {int defaultValue = 0}) async {
    await _ensureLoaded();
    final value = _configCache[key];
    if (value == null) {
      return defaultValue;
    }

    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? defaultValue;

    return defaultValue;
  }

  /// Get a double value
  Future<double> getDouble(String key, {double defaultValue = 0.0}) async {
    try {
      await _ensureLoaded();
      final value = _configCache[key];
      if (value == null) {
        return defaultValue;
      }

      if (value is double) return value;
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? defaultValue;

      return defaultValue;
    } catch (e) {
      return defaultValue;
    }
  }

  /// Get a boolean value
  Future<bool> getBool(String key, {bool defaultValue = false}) async {
    await _ensureLoaded();
    final value = _configCache[key];
    if (value == null) {
      return defaultValue;
    }

    if (value is bool) {
      return value;
    }
    if (value is String) {
      // Handle both 'true'/'false' and '"true"'/'"false"' formats
      final cleaned = value.replaceAll('"', '').toLowerCase().trim();
      return cleaned == 'true';
    }
    if (value is num) {
      return value != 0;
    }

    return defaultValue;
  }

  /// Get a list value
  Future<List<dynamic>> getList(
    String key, {
    List<dynamic> defaultValue = const [],
  }) async {
    await _ensureLoaded();
    final value = _configCache[key];
    if (value == null) {
      return defaultValue;
    }

    if (value is List) return value;

    // Try to parse as JSON if it's a string
    if (value is String) {
      try {
        final parsed = jsonDecode(value);
        if (parsed is List) return parsed;
      } catch (e) {
        // Not valid JSON, return default
      }
    }

    return defaultValue;
  }

  /// Get a list of integers
  Future<List<int>> getIntList(
    String key, {
    List<int> defaultValue = const [],
  }) async {
    final list = await getList(key, defaultValue: defaultValue);
    try {
      return list.map((e) {
        if (e is int) return e;
        if (e is num) return e.toInt();
        if (e is String) return int.tryParse(e) ?? 0;
        return 0;
      }).toList();
    } catch (e) {
      return defaultValue;
    }
  }

  /// Get duration in seconds and return as Duration object
  Future<Duration> getDuration(
    String key, {
    Duration defaultValue = Duration.zero,
  }) async {
    final seconds = await getInt(key, defaultValue: defaultValue.inSeconds);
    return Duration(seconds: seconds);
  }

  /// Get a duration list (in seconds) and return as Duration objects.
  ///
  /// Supports both:
  /// - scalar values (number/string): treated as a single duration
  /// - arrays (List): treated as a list of durations
  Future<List<Duration>> getDurationList(
    String key, {
    List<Duration> defaultValue = const [],
  }) async {
    await _ensureLoaded();
    final raw = _configCache[key];
    if (raw == null) {
      return defaultValue;
    }

    if (raw is List) {
      try {
        return raw
            .map((e) {
              if (e is int) return Duration(seconds: e);
              if (e is num) return Duration(seconds: e.toInt());
              if (e is String) return Duration(seconds: int.tryParse(e) ?? 0);
              return Duration.zero;
            })
            .where((d) => d > Duration.zero)
            .toList();
      } catch (e) {
        return defaultValue;
      }
    }

    if (raw is int) return [Duration(seconds: raw)];
    if (raw is num) return [Duration(seconds: raw.toInt())];
    if (raw is String) {
      final parsed = int.tryParse(raw);
      if (parsed != null) return [Duration(seconds: parsed)];
    }

    return defaultValue;
  }

  /// Get a percentage value (stored as number, but semantic meaning is percentage)
  Future<double> getPercentage(String key, {double defaultValue = 0.0}) async {
    return getDouble(key, defaultValue: defaultValue);
  }

  Future<bool> isSubscriptionEnabled() async {
    return getBool('subscription.enabled', defaultValue: true);
  }

  Future<bool> isInviteFriendsEnabled() async {
    return getBool('referral.enabled', defaultValue: true);
  }

  Future<bool> arePromoCodesEnabled() async {
    return getBool('promo_codes_enabled', defaultValue: true);
  }

  Future<bool> areAdsEnabled() async {
    // Must match the serving RPC's default (app_config_bool
    // 'ads.internal.enabled', false) — when the config row is missing, the
    // server will not serve ads, so the client must not think it will.
    return getBool('ads.internal.enabled', defaultValue: false);
  }

  Future<List<String>> getAdAllowedTiers() async {
    final values = await getList(
      'ads.internal.allowed_tiers',
      defaultValue: const ['free', 'plus', 'gold', 'platinum'],
    );
    final result = <String>[];
    for (final value in values) {
      result.add(value.toString().toLowerCase());
    }
    return result;
  }

  Future<bool> areSponsoredCardsEnabled() async {
    return getBool('ads.internal.sponsored_cards_enabled', defaultValue: true);
  }

  Future<bool> isFamilySafeOnly() async {
    return getBool('ads.internal.family_safe_only', defaultValue: true);
  }

  Future<List<String>> getAdAllowedPlacements() async {
    final values = await getList(
      'ads.internal.allowed_placements',
      defaultValue: const [
        'home_inline',
        'matches_inline',
        'chats_inline',
        'events_inline',
        'profile_inline',
      ],
    );
    final result = <String>[];
    for (final value in values) {
      result.add(value.toString());
    }
    return result;
  }

  Future<int> getAdMaxImpressionsPerSession() async {
    return getInt('ads.internal.max_impressions_per_session', defaultValue: 3);
  }

  Future<Duration> getAdMinInterval() async {
    final minutes = await getInt(
      'ads.internal.min_minutes_between_impressions',
      defaultValue: 8,
    );
    return Duration(minutes: minutes);
  }

  Future<Duration> getAdFirstImpressionDelay() async {
    final seconds = await getInt(
      'ads.internal.first_impression_delay_seconds',
      defaultValue: 90,
    );
    return Duration(seconds: seconds);
  }

  Future<bool> isAdReportingEnabled() async {
    return getBool('ads.internal.report_enabled', defaultValue: true);
  }

  Future<Duration> getForcedSignOutDuration() async {
    final days = await getInt('auth.forced_sign_out_days', defaultValue: 0);
    if (days <= 0) return Duration.zero;
    return Duration(days: days);
  }

  Future<bool> isPasskeysEnabled() async {
    return getBool('auth.passkeys.enabled', defaultValue: false);
  }

  Future<String> getPasskeysRelyingPartyId() async {
    // Check if development mode is enabled
    final isDevelopmentMode = await getBool(
      'auth.passkeys.development_mode',
      defaultValue: false,
    );

    if (isDevelopmentMode) {
      final devRpId = (await getString(
        'auth.passkeys.development_rp_id',
        defaultValue: 'localhost',
      )).trim();
      if (devRpId.isNotEmpty) {
        return devRpId;
      }
    }

    final prodRpId = await getString(
      'auth.passkeys.relying_party_id',
      defaultValue: '',
    );
    return prodRpId;
  }

  Future<String> getPasskeysServerBaseUrl() async {
    return getString('auth.passkeys.server_base_url', defaultValue: '');
  }

  Future<String> getPasskeysStartAuthenticationPath() async {
    final raw = (await getString(
      'auth.passkeys.start_authentication_path',
      defaultValue: '/functions/v1/passkeys-authentication-start',
    )).trim();
    if (raw.isEmpty) return '/functions/v1/passkeys-authentication-start';
    return raw.startsWith('/') ? raw : '/$raw';
  }

  Future<String> getPasskeysFinishAuthenticationPath() async {
    final raw = (await getString(
      'auth.passkeys.finish_authentication_path',
      defaultValue: '/functions/v1/passkeys-authentication-finish',
    )).trim();
    if (raw.isEmpty) return '/functions/v1/passkeys-authentication-finish';
    return raw.startsWith('/') ? raw : '/$raw';
  }

  Future<String> getPasskeysStartRegistrationPath() async {
    final raw = (await getString(
      'auth.passkeys.start_registration_path',
      defaultValue: '/functions/v1/passkeys-registration-start',
    )).trim();
    if (raw.isEmpty) return '/functions/v1/passkeys-registration-start';
    return raw.startsWith('/') ? raw : '/$raw';
  }

  Future<String> getPasskeysFinishRegistrationPath() async {
    final raw = (await getString(
      'auth.passkeys.finish_registration_path',
      defaultValue: '/functions/v1/passkeys-registration-finish',
    )).trim();
    if (raw.isEmpty) return '/functions/v1/passkeys-registration-finish';
    return raw.startsWith('/') ? raw : '/$raw';
  }

  Future<PasskeysRuntimeConfig> getPasskeysRuntimeConfig() async {
    final relyingPartyId = (await getPasskeysRelyingPartyId()).trim();
    final serverBaseUrl = (await getPasskeysServerBaseUrl()).trim();

    final config = PasskeysRuntimeConfig(
      relyingPartyId: relyingPartyId,
      serverBaseUrl: serverBaseUrl,
    );

    return config;
  }

  Future<bool> isPasskeysRuntimeConfigured() async {
    final runtimeConfig = await getPasskeysRuntimeConfig();
    if (!runtimeConfig.isValid) {
      return false;
    }
    if (!kIsWeb) {
      return true;
    }
    return runtimeConfig.isCompatibleWithWebHost(_getCurrentWebHost());
  }

  String _getCurrentWebHost() {
    if (!kIsWeb) {
      return '';
    }
    final href = html.window.location.href;
    return Uri.tryParse(href)?.host ?? '';
  }

  /// Force refresh the cache
  Future<void> refresh() async {
    if (_isLoading) {
      await _loadCompleter?.future;
      return;
    }

    _isLoading = true;
    _loadCompleter = Completer<void>();

    try {
      await _loadAllConfig();
      _lastTransientFailureAt = null;
      _hasInitialized = true;
      _loadCompleter!.complete();
    } catch (e) {
      if (_isTransientNetworkError(e)) {
        _lastTransientFailureAt = DateTime.now();
      }
      _loadCompleter!.complete();
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// Get all configs in a category
  Future<Map<String, dynamic>> getCategory(String category) async {
    await _ensureLoaded();
    final categoryConfigs = <String, dynamic>{};

    for (final entry in _configCache.entries) {
      if (entry.key.startsWith('$category.')) {
        categoryConfigs[entry.key] = entry.value;
      }
    }

    return categoryConfigs;
  }

  /// Check if a config key exists
  Future<bool> hasKey(String key) async {
    await _ensureLoaded();
    return _configCache.containsKey(key);
  }

  /// Get raw value (for debugging)
  Future<dynamic> getRaw(String key) async {
    await _ensureLoaded();
    return _configCache[key];
  }

  /// Clear cache (mainly for testing)
  void clearCache() {
    _configCache.clear();
    _lastFetchTime = null;
    _lastTransientFailureAt = null;
    _hasInitialized = false;
  }
}

/// Provider-friendly singleton instance
final appConfigService = AppConfigService();
