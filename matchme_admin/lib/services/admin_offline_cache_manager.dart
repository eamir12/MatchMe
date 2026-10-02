// lib/services/admin_offline_cache_manager.dart
// Service for managing comprehensive offline caching and fallback data strategy
// Provides cached data when Supabase is unavailable

import 'dart:async';
import 'package:matchme_admin/services/admin_local_db_service.dart';

/// Manages offline-first caching and provides fallback data for admin app
class AdminOfflineCacheManager {
  static final AdminOfflineCacheManager _instance =
      AdminOfflineCacheManager._internal();
  static const Duration _transientFailureGracePeriod = Duration(seconds: 3);
  static const int _requiredConsecutiveUnavailableSignals = 2;

  /// Get the singleton instance of AdminOfflineCacheManager
  static AdminOfflineCacheManager get instance => _instance;

  factory AdminOfflineCacheManager() => _instance;

  AdminOfflineCacheManager._internal();

  bool _isSupabaseAvailable = true;
  DateTime? _lastSupabaseCheckTime;
  DateTime? _lastSupabaseAvailableAt = DateTime.now();
  DateTime? _pendingUnavailableSince;
  int _consecutiveUnavailableSignals = 0;

  /// Stream controller for availability changes
  final _availabilityController = StreamController<bool>.broadcast();
  Stream<bool> get availabilityStream => _availabilityController.stream;

  /// Check if Supabase is currently available
  bool get isSupabaseAvailable => _isSupabaseAvailable;

  /// Set the Supabase availability status (used by connectivity monitoring)
  void setSupabaseAvailability(bool available, {bool force = false}) {
    final now = DateTime.now();
    _lastSupabaseCheckTime = now;

    if (force) {
      _pendingUnavailableSince = null;
      _consecutiveUnavailableSignals = 0;
      _applyAvailability(available, now);
      return;
    }

    if (available) {
      _pendingUnavailableSince = null;
      _consecutiveUnavailableSignals = 0;
      _applyAvailability(true, now);
      return;
    }

    if (!_isSupabaseAvailable) {
      return;
    }

    _pendingUnavailableSince ??= now;
    _consecutiveUnavailableSignals += 1;

    final graceElapsed =
        _lastSupabaseAvailableAt == null ||
        now.difference(_lastSupabaseAvailableAt!) >=
            _transientFailureGracePeriod;
    final enoughSignals =
        _consecutiveUnavailableSignals >=
        _requiredConsecutiveUnavailableSignals;

    if (graceElapsed && enoughSignals) {
      _applyAvailability(false, now);
      return;
    }
  }

  void _applyAvailability(bool available, DateTime timestamp) {
    if (available != _isSupabaseAvailable) {
      _availabilityController.add(available);
    }
    _isSupabaseAvailable = available;
    _lastSupabaseCheckTime = timestamp;
    if (available) {
      _lastSupabaseAvailableAt = timestamp;
    }
  }

  /// Check if we should consider Supabase as unavailable based on cached status
  bool shouldUseCachedData() {
    return !_isSupabaseAvailable;
  }

  Future<List<Map<String, dynamic>>> getCachedPromoCodes() async {
    try {
      final localDb = await AdminLocalDbService.instance;
      return await localDb.loadPromoCodes();
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>?> getCachedPromoAnalytics() async {
    try {
      final localDb = await AdminLocalDbService.instance;
      return await localDb.loadPromoAnalytics();
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getCachedAppConfig() async {
    try {
      final localDb = await AdminLocalDbService.instance;
      return await localDb.loadAppConfig();
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getCachedSponsoredAds() async {
    try {
      final localDb = await AdminLocalDbService.instance;
      return await localDb.loadSponsoredAds();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getCachedAdNetworks() async {
    try {
      final localDb = await AdminLocalDbService.instance;
      return await localDb.loadAdNetworks();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getCachedAdUnits() async {
    try {
      final localDb = await AdminLocalDbService.instance;
      return await localDb.loadAdUnits();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getCachedExternalAds() async {
    try {
      final localDb = await AdminLocalDbService.instance;
      return await localDb.loadExternalAds();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getCachedExternalAdCampaigns() async {
    try {
      final localDb = await AdminLocalDbService.instance;
      return await localDb.loadExternalAdCampaigns();
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>?> getCachedAdRevenue() async {
    try {
      final localDb = await AdminLocalDbService.instance;
      return await localDb.loadAdRevenue();
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> getCacheStats() async {
    try {
      final localDb = await AdminLocalDbService.instance;
      final stats = await localDb.getCacheStats();
      stats['isSupabaseAvailable'] = _isSupabaseAvailable;
      stats['lastSupabaseCheckTime'] = _lastSupabaseCheckTime
          ?.toIso8601String();
      stats['lastSupabaseAvailableAt'] = _lastSupabaseAvailableAt
          ?.toIso8601String();
      return stats;
    } catch (_) {
      return {'isSupabaseAvailable': _isSupabaseAvailable};
    }
  }

  /// Dispose resources
  void dispose() {
    _availabilityController.close();
  }
}

/// Global singleton instance for easy access
final adminOfflineCacheManager = AdminOfflineCacheManager.instance;
