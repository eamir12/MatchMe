// lib/services/admin_sync_manager.dart
// Sync manager for admin app - coordinates syncing with Supabase when online

import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:matchme_admin/services/admin_local_db_service.dart';
import 'package:matchme_admin/services/admin_offline_cache_manager.dart';
import 'package:matchme_admin/services/public_reference_data_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Provider for the admin sync manager
final adminSyncManagerProvider = Provider<AdminSyncManager>((ref) {
  return AdminSyncManager(ref);
});

/// Sync status enum
enum AdminSyncStatus { idle, offline, error }

/// This service manages syncing of admin data with Supabase
class AdminSyncManager {
  final Ref _ref;
  Timer? _syncTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  // Prevent rapid sync restarts when connectivity bounces
  DateTime? _lastSyncAttempt;
  static const Duration _syncCooldown = Duration(seconds: 30);

  // Track sync in progress to prevent concurrent syncs
  bool _syncInProgress = false;

  // Current sync status
  AdminSyncStatus _syncStatus = AdminSyncStatus.idle;

  // Last sync times for each data type
  final Map<String, DateTime?> _lastSyncTimes = {};

  // Track app lifecycle state to avoid false offline detection when backgrounded
  bool _isInForeground = true;

  // Track initial sync so it runs on first successful connectivity check
  bool _hasInitialSyncCompleted = false;

  AdminSyncManager(this._ref) {
    // Start monitoring connectivity
    _startConnectivityMonitoring();

    // Clean up timers if this provider is disposed
    _ref.onDispose(() {
      _syncTimer?.cancel();
      _connectivitySubscription?.cancel();
    });
  }

  /// Notify the sync manager of app lifecycle changes.
  /// Call this from WidgetsBindingObserver.didChangeAppLifecycleState
  void onAppLifecycleStateChanged(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _isInForeground = true;
        _checkConnectivity();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _isInForeground = false;
    }
  }

  void _startConnectivityMonitoring() {
    // Listen for OS-level network transport changes (WiFi on/off, etc.)
    // so we can probe immediately instead of waiting for the next timer tick.
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      _,
    ) {
      _checkConnectivity();
      // Cooldown is checked inside syncAll, so repeated rapid events
      // won't trigger multiple syncs.
    });

    // Periodic probe as a safety net (handles cases where the OS event
    // doesn't fire, e.g. unstable WiFi that stays "connected" but can't
    // reach the internet).
    Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_isInForeground) return;
      await _checkConnectivity();
    });

    // Initial check
    _checkConnectivity();
  }

  Future<void> _checkConnectivity() async {
    bool isOnline;
    try {
      await Supabase.instance.client
          .rpc('get_current_timestamp')
          .timeout(const Duration(seconds: 5));
      isOnline = true;
    } catch (e) {
      if (!_isInForeground) return;

      final typeName = e.runtimeType.toString().toLowerCase();
      final errorText = e.toString().toLowerCase();

      // Match by runtime type for common network exception classes
      final networkType =
          typeName.contains('sockete') ||
          typeName.contains('timeout') ||
          typeName.contains('clientexception') ||
          typeName.contains('httpexception') ||
          typeName.contains('handshakeexception') ||
          typeName.contains('tlssexception');

      // Match by error text as a broad fallback
      final networkText =
          errorText.contains('failed host lookup') ||
          errorText.contains('unreachable') ||
          errorText.contains('connection refused') ||
          errorText.contains('connection reset') ||
          errorText.contains('no address associated') ||
          errorText.contains('failed to connect') ||
          errorText.contains('network is unreachable') ||
          errorText.contains('connection timed out') ||
          errorText.contains('no route to host') ||
          errorText.contains('host unreachable') ||
          errorText.contains('no such host') ||
          (errorText.contains('connection') &&
              (errorText.contains('failed') ||
                  errorText.contains('error') ||
                  errorText.contains('timed out') ||
                  errorText.contains('closed') ||
                  errorText.contains('reset')));

      isOnline = !(networkType || networkText);
    }

    if (!_isInForeground) return;

    if (isOnline) {
      final wasOffline = adminOfflineCacheManager.shouldUseCachedData();
      adminOfflineCacheManager.setSupabaseAvailability(true);
      _syncStatus = AdminSyncStatus.idle;

      if (wasOffline || !_hasInitialSyncCompleted) {
        _hasInitialSyncCompleted = true;
        // Fire-and-forget: sync runs in background so a timeout never
        // corrupts the online/offline state determined above.
        unawaited(syncAll());
      }
    } else {
      adminOfflineCacheManager.setSupabaseAvailability(false);
      _syncStatus = AdminSyncStatus.offline;
    }
  }

  /// Force a sync of all data types
  Future<void> syncAll({bool skipCooldown = false}) async {
    if (_syncInProgress) return;

    if (!skipCooldown && _lastSyncAttempt != null) {
      final timeSinceLastSync = DateTime.now().difference(_lastSyncAttempt!);
      if (timeSinceLastSync < _syncCooldown) return;
    }

    if (adminOfflineCacheManager.shouldUseCachedData()) {
      _syncStatus = AdminSyncStatus.offline;
      return;
    }

    _syncInProgress = true;
    _lastSyncAttempt = DateTime.now();

    try {
      await Future.wait([
        _syncPromoCodes(),
        _syncAppConfig(),
        _syncSponsoredAds(),
        _syncAdNetworks(),
        _syncAdUnits(),
        _syncAdRevenue(),
        _syncBroadcasts(),
        _syncSupportedLanguages(),
        _syncSubscriptions(),
        _syncIntentsInterests(),
        _syncVerificationUsers(),
        _syncProfileEditRequests(),
      ]).timeout(const Duration(seconds: 120));

      _syncStatus = AdminSyncStatus.idle;
    } catch (e) {
      _syncStatus = AdminSyncStatus.error;
    } finally {
      _syncInProgress = false;
    }
  }

  Future<void> _syncPromoCodes() async {
    try {
      final response = await Supabase.instance.client
          .from('promo_codes')
          .select()
          .order('is_active', ascending: false)
          .order('created_at', ascending: false)
          .timeout(const Duration(seconds: 10));

      final codes = List<Map<String, dynamic>>.from(response);
      final localDb = await AdminLocalDbService.instance;
      await localDb.savePromoCodes(codes);

      _updateLastSyncTime('promo_codes');
    } catch (_) {}
  }

  Future<void> _syncAppConfig() async {
    try {
      final response = await Supabase.instance.client
          .from('app_config')
          .select()
          .timeout(const Duration(seconds: 10));

      final config = <String, dynamic>{};
      for (final row in List<Map<String, dynamic>>.from(response)) {
        config[row['config_key'] as String] = row['config_value'];
      }

      final localDb = await AdminLocalDbService.instance;
      await localDb.saveAppConfig(config);

      _updateLastSyncTime('app_config');
    } catch (_) {}
  }

  Future<void> _syncSponsoredAds() async {
    try {
      final response = await Supabase.instance.client
          .from('ad_campaigns')
          .select()
          .order('created_at', ascending: false)
          .timeout(const Duration(seconds: 10));

      final ads = List<Map<String, dynamic>>.from(response);
      final localDb = await AdminLocalDbService.instance;
      await localDb.saveSponsoredAds(ads);

      _updateLastSyncTime('sponsored_ads');
    } catch (_) {}
  }

  Future<void> _syncAdNetworks() async {
    try {
      final response = await Supabase.instance.client
          .from('ad_networks')
          .select()
          .order('display_name', ascending: true)
          .timeout(const Duration(seconds: 10));

      final networks = List<Map<String, dynamic>>.from(response);
      final localDb = await AdminLocalDbService.instance;
      await localDb.saveAdNetworks(networks);

      _updateLastSyncTime('ad_networks');
    } catch (_) {}
  }

  Future<void> _syncAdUnits() async {
    try {
      final response = await Supabase.instance.client
          .from('ad_units')
          .select()
          .order('placement', ascending: true)
          .timeout(const Duration(seconds: 10));

      final units = List<Map<String, dynamic>>.from(response);
      final localDb = await AdminLocalDbService.instance;
      await localDb.saveAdUnits(units);

      _updateLastSyncTime('ad_units');
    } catch (_) {}
  }

  Future<void> _syncAdRevenue() async {
    try {
      final response = await Supabase.instance.client
          .from('ad_revenue_events')
          .select()
          .order('created_at', ascending: false)
          .limit(100)
          .timeout(const Duration(seconds: 10));

      final revenue = <String, dynamic>{
        'entries': List<Map<String, dynamic>>.from(response),
        'last_updated': DateTime.now().toIso8601String(),
      };

      final localDb = await AdminLocalDbService.instance;
      await localDb.saveAdRevenue(revenue);

      _updateLastSyncTime('ad_revenue');
    } catch (_) {}
  }

  Future<void> _syncBroadcasts() async {
    try {
      final response = await Supabase.instance.client
          .from('admin_broadcasts')
          .select(
            'id, title, message, message_type, automation_type, automation_enabled, action_url, action_url_text, scheduled_at, sent_at, status, filter_criteria, skipped_count, target_user_count, actual_sent_count, created_by, created_at, updated_at',
          )
          .order('created_at', ascending: false)
          .limit(500)
          .timeout(const Duration(seconds: 12));
      final rows = List<Map<String, dynamic>>.from(
        response,
      ).map((r) => Map<String, dynamic>.from(r as Map)).toList(growable: false);
      final localDb = await AdminLocalDbService.instance;
      await localDb.saveSectionData('broadcasts', rows);
      _updateLastSyncTime('broadcasts');
    } catch (_) {}
  }

  Future<void> _syncSupportedLanguages() async {
    try {
      final rows = await publicReferenceDataService
          .fetchSupportedLanguages()
          .timeout(const Duration(seconds: 10));
      final localDb = await AdminLocalDbService.instance;
      await localDb.saveSectionData('supported_languages', rows);
      _updateLastSyncTime('supported_languages');
    } catch (_) {}
  }

  Future<void> _syncTranslations() async {
    try {
      final byKey = <String, Map<String, String>>{};
      for (final locale in const ['en', 'es', 'he']) {
        try {
          final rows = await publicReferenceDataService
              .fetchTranslations(locale)
              .timeout(const Duration(seconds: 15));
          for (final entry in rows.entries) {
            final key = entry.key.trim();
            if (key.isEmpty) continue;
            (byKey[key] ??= <String, String>{})[locale] = entry.value;
          }
        } catch (_) {
          // Continue with other locales even if one fails
        }
      }
      final groups = byKey.entries
          .map(
            (e) => <String, String>{
              'key': e.key,
              'en': e.value['en'] ?? '',
              'es': e.value['es'] ?? '',
              'he': e.value['he'] ?? '',
            },
          )
          .toList(growable: false);
      final localDb = await AdminLocalDbService.instance;
      await localDb.saveSectionData('translation_groups', groups);
      _updateLastSyncTime('translations');
    } catch (_) {}
  }

  Future<void> _syncSubscriptions() async {
    try {
      final client = Supabase.instance.client;
      final tierRows = await client
          .from('subscription_tiers')
          .select()
          .order('sort_order', ascending: true)
          .timeout(const Duration(seconds: 10));
      final planRows = await client
          .from('subscription_plans')
          .select()
          .order('tier_id', ascending: true)
          .order('sort_order', ascending: true)
          .timeout(const Duration(seconds: 10));
      final rawTiers = List<Map<String, dynamic>>.from(
        tierRows,
      ).map((r) => Map<String, dynamic>.from(r)).toList(growable: false);
      final rawPlans = List<Map<String, dynamic>>.from(
        planRows,
      ).map((r) => Map<String, dynamic>.from(r)).toList(growable: false);
      final localDb = await AdminLocalDbService.instance;
      await localDb.saveSectionDataMap('subscriptions', <String, dynamic>{
        'tiers': rawTiers,
        'plans': rawPlans,
      });
      _updateLastSyncTime('subscriptions');
    } catch (_) {}
  }

  Future<void> _syncIntentsInterests() async {
    try {
      final client = Supabase.instance.client;
      final localDb = await AdminLocalDbService.instance;
      final intents = await client
          .rpc('admin_list_intents')
          .timeout(const Duration(seconds: 10));
      final intentsList = (intents is List ? intents : const [])
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList(growable: false);
      await localDb.saveSectionData('intents', intentsList);
      final interests = await client
          .rpc('admin_list_interests')
          .timeout(const Duration(seconds: 10));
      final interestsList = (interests is List ? interests : const [])
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList(growable: false);
      await localDb.saveSectionData('interests', interestsList);
      _updateLastSyncTime('intents_interests');
    } catch (_) {}
  }

  Future<void> _syncVerificationUsers() async {
    try {
      final result = await Supabase.instance.client
          .rpc(
            'admin_list_verification_users',
            params: {
              'p_status': null,
              'p_query': null,
              'p_limit': 200,
              'p_offset': 0,
            },
          )
          .timeout(const Duration(seconds: 12));
      final list = (result as List<dynamic>).cast<dynamic>();
      final raw = list
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      final localDb = await AdminLocalDbService.instance;
      await localDb.saveSectionData('verification_users:all:none', raw);
      _updateLastSyncTime('verification_users');
    } catch (_) {}
  }

  Future<void> _syncProfileEditRequests() async {
    try {
      final result = await Supabase.instance.client
          .rpc(
            'admin_list_profile_edit_requests',
            params: {
              'p_status': null,
              'p_query': null,
              'p_limit': 200,
              'p_offset': 0,
            },
          )
          .timeout(const Duration(seconds: 12));
      final list = (result as List<dynamic>).cast<dynamic>();
      final raw = list
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      final localDb = await AdminLocalDbService.instance;
      await localDb.saveSectionData('profile_edit_requests:all:none', raw);
      _updateLastSyncTime('profile_edit_requests');
    } catch (_) {}
  }

  void _updateLastSyncTime(String dataType) {
    _lastSyncTimes[dataType] = DateTime.now();
  }

  /// Get the last sync time for a specific data type
  DateTime? getLastSyncTime(String dataType) {
    return _lastSyncTimes[dataType];
  }

  /// Get current sync status
  AdminSyncStatus get syncStatus => _syncStatus;

  /// Trigger a specific data type sync
  Future<void> syncDataType(String dataType) async {
    if (adminOfflineCacheManager.shouldUseCachedData()) return;

    switch (dataType) {
      case 'promo_codes':
        await _syncPromoCodes();
      case 'app_config':
        await _syncAppConfig();
      case 'sponsored_ads':
        await _syncSponsoredAds();
      case 'ad_networks':
        await _syncAdNetworks();
      case 'ad_units':
        await _syncAdUnits();
      case 'ad_revenue':
        await _syncAdRevenue();
      case 'broadcasts':
        await _syncBroadcasts();
      case 'supported_languages':
        await _syncSupportedLanguages();
      case 'translations':
        await _syncTranslations();
      case 'subscriptions':
        await _syncSubscriptions();
      case 'intents_interests':
        await _syncIntentsInterests();
      case 'verification_users':
        await _syncVerificationUsers();
      case 'profile_edit_requests':
        await _syncProfileEditRequests();
      default:
      // Unknown data type - ignored
    }
  }

  /// Clear all cached data
  Future<void> clearAllCache() async {
    final localDb = await AdminLocalDbService.instance;
    await localDb.clearAll();
    _lastSyncTimes.clear();
  }
}
