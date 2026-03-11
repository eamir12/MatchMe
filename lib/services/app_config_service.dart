// lib/services/app_config_service.dart
// Service for fetching and caching application configuration from the app_config table

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Centralized service for accessing application configuration
/// Caches config values for performance and provides type-safe access
class AppConfigService {
  static final AppConfigService _instance = AppConfigService._internal();
  factory AppConfigService() => _instance;
  AppConfigService._internal();

  final _supabase = Supabase.instance.client;
  
  // Cache for config values
  final Map<String, dynamic> _configCache = {};
  DateTime? _lastFetchTime;
  
  // Cache duration: refresh every 5 minutes
  static const Duration _cacheDuration = Duration(minutes: 5);
  
  // Loading state
  bool _isLoading = false;
  Completer<void>? _loadCompleter;

  /// Initialize and load all config from database
  /// Call this once at app startup
  Future<void> initialize() async {
    if (_isLoading) {
      // If already loading, wait for that operation to complete
      await _loadCompleter?.future;
      return;
    }

    _isLoading = true;
    _loadCompleter = Completer<void>();

    try {
      debugPrint('📋 [AppConfig] Initializing app configuration...');
      await _loadAllConfig();
      debugPrint('📋 [AppConfig] Loaded ${_configCache.length} configuration entries');
      _loadCompleter!.complete();
    } catch (e) {
      debugPrint('❌ [AppConfig] Failed to initialize: $e');
      _loadCompleter!.completeError(e);
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// Load all configuration from database
  Future<void> _loadAllConfig() async {
    try {
      final response = await _supabase
          .from('app_config')
          .select('config_key, config_value, config_type');

      _configCache.clear();
      for (final row in response) {
        final key = row['config_key'] as String;
        final value = row['config_value'];
        final type = row['config_type'] as String;
        
        // Parse value based on type
        _configCache[key] = _parseConfigValue(value, type);
      }
      _lastFetchTime = DateTime.now();
    } catch (e) {
      debugPrint('❌ [AppConfig] Error loading config: $e');
      rethrow;
    }
  }

  /// Parse config value based on its type
  dynamic _parseConfigValue(dynamic value, String type) {
    if (value == null) return null;

    try {
      switch (type) {
        case 'number':
        case 'duration_seconds':
        case 'percentage':
          // Value is already a number or stored as string
          if (value is num) return value;
          if (value is String) return num.tryParse(value);
          return value;
          
        case 'boolean':
          if (value is bool) return value;
          if (value is String) return value.toLowerCase() == 'true';
          return value;
          
        case 'string':
          return value.toString();
          
        case 'array':
          // JSONB arrays come as List already
          if (value is List) return value;
          // If stored as string JSON, would need to parse
          return value;
          
        default:
          return value;
      }
    } catch (e) {
      debugPrint('⚠️ [AppConfig] Error parsing value for type $type: $e');
      return value;
    }
  }

  /// Check if cache needs refresh
  bool _shouldRefreshCache() {
    if (_lastFetchTime == null) return true;
    return DateTime.now().difference(_lastFetchTime!) > _cacheDuration;
  }

  /// Refresh cache if needed
  Future<void> _ensureLoaded() async {
    if (_configCache.isEmpty || _shouldRefreshCache()) {
      await initialize();
    }
  }

  /// Get a string value
  Future<String> getString(String key, {String defaultValue = ''}) async {
    await _ensureLoaded();
    final value = _configCache[key];
    if (value == null) {
      debugPrint('⚠️ [AppConfig] Config key not found: $key, using default: $defaultValue');
      return defaultValue;
    }
    return value.toString();
  }

  /// Get an integer value
  Future<int> getInt(String key, {int defaultValue = 0}) async {
    await _ensureLoaded();
    final value = _configCache[key];
    if (value == null) {
      debugPrint('⚠️ [AppConfig] Config key not found: $key, using default: $defaultValue');
      return defaultValue;
    }
    
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? defaultValue;
    
    debugPrint('⚠️ [AppConfig] Cannot parse $key as int: $value, using default: $defaultValue');
    return defaultValue;
  }

  /// Get a double value
  Future<double> getDouble(String key, {double defaultValue = 0.0}) async {
    await _ensureLoaded();
    final value = _configCache[key];
    if (value == null) {
      debugPrint('⚠️ [AppConfig] Config key not found: $key, using default: $defaultValue');
      return defaultValue;
    }
    
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? defaultValue;
    
    debugPrint('⚠️ [AppConfig] Cannot parse $key as double: $value, using default: $defaultValue');
    return defaultValue;
  }

  /// Get a boolean value
  Future<bool> getBool(String key, {bool defaultValue = false}) async {
    await _ensureLoaded();
    final value = _configCache[key];
    if (value == null) {
      debugPrint('⚠️ [AppConfig] Config key not found: $key, using default: $defaultValue');
      return defaultValue;
    }
    
    if (value is bool) return value;
    if (value is String) return value.toLowerCase() == 'true';
    if (value is num) return value != 0;
    
    debugPrint('⚠️ [AppConfig] Cannot parse $key as bool: $value, using default: $defaultValue');
    return defaultValue;
  }

  /// Get a list value
  Future<List<dynamic>> getList(String key, {List<dynamic> defaultValue = const []}) async {
    await _ensureLoaded();
    final value = _configCache[key];
    if (value == null) {
      debugPrint('⚠️ [AppConfig] Config key not found: $key, using default: $defaultValue');
      return defaultValue;
    }
    
    if (value is List) return value;
    
    debugPrint('⚠️ [AppConfig] Cannot parse $key as List: $value, using default: $defaultValue');
    return defaultValue;
  }

  /// Get a list of integers
  Future<List<int>> getIntList(String key, {List<int> defaultValue = const []}) async {
    final list = await getList(key, defaultValue: defaultValue);
    try {
      return list.map((e) {
        if (e is int) return e;
        if (e is num) return e.toInt();
        if (e is String) return int.tryParse(e) ?? 0;
        return 0;
      }).toList();
    } catch (e) {
      debugPrint('⚠️ [AppConfig] Error parsing $key as int list: $e');
      return defaultValue;
    }
  }

  /// Get duration in seconds and return as Duration object
  Future<Duration> getDuration(String key, {Duration defaultValue = Duration.zero}) async {
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
      debugPrint('⚠️ [AppConfig] Config key not found: $key, using default: $defaultValue');
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
        debugPrint('⚠️ [AppConfig] Error parsing $key as duration list: $e');
        return defaultValue;
      }
    }

    if (raw is int) return [Duration(seconds: raw)];
    if (raw is num) return [Duration(seconds: raw.toInt())];
    if (raw is String) {
      final parsed = int.tryParse(raw);
      if (parsed != null) return [Duration(seconds: parsed)];
    }

    debugPrint('⚠️ [AppConfig] Cannot parse $key as duration list: $raw, using default: $defaultValue');
    return defaultValue;
  }

  /// Get a percentage value (stored as number, but semantic meaning is percentage)
  Future<double> getPercentage(String key, {double defaultValue = 0.0}) async {
    return getDouble(key, defaultValue: defaultValue);
  }

  /// Force refresh the cache
  Future<void> refresh() async {
    debugPrint('📋 [AppConfig] Force refreshing configuration...');
    await _loadAllConfig();
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
    debugPrint('📋 [AppConfig] Cache cleared');
  }
}

/// Provider-friendly singleton instance
final appConfigService = AppConfigService();
