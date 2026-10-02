// lib/services/admin_local_db_service.dart
// Local DB service (Hive) for admin app data caching

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hive_flutter/hive_flutter.dart';
import 'dart:convert';
import 'dart:async';

// --- Hive Box Names ---
const String _kPromoCodesBox = 'adminPromoCodesBox';
const String _kAppConfigBox = 'adminAppConfigBox';
const String _kSponsoredAdsBox = 'adminSponsoredAdsBox';
const String _kAdNetworksBox = 'adminAdNetworksBox';
const String _kAdUnitsBox = 'adminAdUnitsBox';
const String _kExternalAdsBox = 'adminExternalAdsBox';
const String _kAdRevenueBox = 'adminAdRevenueBox';
const String _kDashboardBox = 'adminDashboardBox';
const String _kMetadataBox = 'adminMetadataBox';
const String _kSectionsBox = 'adminSectionsBox';

class AdminLocalDbService {
  static AdminLocalDbService? _instance;
  static AdminLocalDbService get shared {
    _instance ??= AdminLocalDbService();
    return _instance!;
  }

  static Future<AdminLocalDbService> get instance async {
    _instance ??= shared;
    await _instance!.init();
    return _instance!;
  }

  Box<String>? _promoCodesBox;
  Box<String>? _appConfigBox;
  Box<String>? _sponsoredAdsBox;
  Box<String>? _adNetworksBox;
  Box<String>? _adUnitsBox;
  Box<String>? _externalAdsBox;
  Box<String>? _adRevenueBox;
  Box<String>? _dashboardBox;
  Box<String>? _metadataBox;
  Box<String>? _sectionsBox;
  bool _initialized = false;
  Completer<void>? _initCompleter;

  Future<void> init() async {
    if (_initialized) return;
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }
    _initCompleter = Completer<void>();

    try {
      // Initialize Hive
      if (!kIsWeb) {
        // On mobile/desktop, Hive uses path_provider internally via hive_flutter
        await Hive.initFlutter('admin_hive');
      } else {
        // On web, Hive uses IndexedDB
        await Hive.initFlutter();
      }

      // Open all boxes in parallel
      await Future.wait([
        Hive.openBox<String>(
          _kPromoCodesBox,
        ).then((box) => _promoCodesBox = box),
        Hive.openBox<String>(_kAppConfigBox).then((box) => _appConfigBox = box),
        Hive.openBox<String>(
          _kSponsoredAdsBox,
        ).then((box) => _sponsoredAdsBox = box),
        Hive.openBox<String>(
          _kAdNetworksBox,
        ).then((box) => _adNetworksBox = box),
        Hive.openBox<String>(_kAdUnitsBox).then((box) => _adUnitsBox = box),
        Hive.openBox<String>(
          _kExternalAdsBox,
        ).then((box) => _externalAdsBox = box),
        Hive.openBox<String>(_kAdRevenueBox).then((box) => _adRevenueBox = box),
        Hive.openBox<String>(_kDashboardBox).then((box) => _dashboardBox = box),
        Hive.openBox<String>(_kMetadataBox).then((box) => _metadataBox = box),
        Hive.openBox<String>(_kSectionsBox).then((box) => _sectionsBox = box),
      ]);

      _initialized = true;
      _initCompleter!.complete();
      _initCompleter = null;
    } catch (e) {
      _initCompleter!.completeError(e);
      _initCompleter = null;
      rethrow;
    }
  }

  // ========== Promo Codes ==========
  Future<void> savePromoCodes(List<Map<String, dynamic>> codes) async {
    await _getPromoCodesBox().put('codes', jsonEncode(codes));
    await _updateLastSyncTime('promo_codes');
  }

  Future<List<Map<String, dynamic>>> loadPromoCodes() async {
    final raw = _getPromoCodesBox().get('codes');
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> savePromoAnalytics(Map<String, dynamic> analytics) async {
    await _getPromoCodesBox().put('analytics', jsonEncode(analytics));
  }

  Future<Map<String, dynamic>?> loadPromoAnalytics() async {
    final raw = _getPromoCodesBox().get('analytics');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  // ========== App Config ==========
  Future<void> saveAppConfig(Map<String, dynamic> config) async {
    await _getAppConfigBox().put('config', jsonEncode(config));
    await _updateLastSyncTime('app_config');
  }

  /// Clear only the app config cache
  Future<void> clearAppConfig() async {
    await _getAppConfigBox().clear();
  }

  /// Drop only the named keys from the cached app config snapshot.
  ///
  /// Prefer this over [clearAppConfig] when a screen owns a subset of the
  /// config keys: clearing the whole box also discards config cached for
  /// unrelated admin screens, forcing them to re-fetch.
  Future<void> removeAppConfigKeys(List<String> keys) async {
    if (keys.isEmpty) return;
    final current = await loadAppConfig() ?? <String, dynamic>{};
    var changed = false;
    for (final key in keys) {
      if (current.remove(key) != null) changed = true;
    }
    if (!changed) return;
    final box = _getAppConfigBox();
    if (current.isEmpty) {
      await box.delete('config');
    } else {
      await box.put('config', jsonEncode(current));
    }
    await _updateLastSyncTime('app_config');
  }

  Future<Map<String, dynamic>?> loadAppConfig() async {
    final raw = _getAppConfigBox().get('config');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Synchronous version of loadAppConfig for immediate UI rendering
  Map<String, dynamic>? loadAppConfigSync() {
    if (!_initialized) return null;
    try {
      final raw = _getAppConfigBox().get('config');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as Map;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Synchronous version of loadPromoCodes
  List<Map<String, dynamic>> loadPromoCodesSync() {
    if (!_initialized) return [];
    try {
      final raw = _getPromoCodesBox().get('codes');
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Synchronous version of loadPromoAnalytics
  Map<String, dynamic>? loadPromoAnalyticsSync() {
    if (!_initialized) return null;
    try {
      final raw = _getPromoCodesBox().get('analytics');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as Map;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> savePromoCodesConfig(bool enabled) async {
    await _getAppConfigBox().put(
      'promo_codes_enabled',
      jsonEncode({'enabled': enabled}),
    );
  }

  Future<bool> loadPromoCodesConfig() async {
    final raw = _getAppConfigBox().get('promo_codes_enabled');
    if (raw == null || raw.isEmpty) return true;
    try {
      final decoded = jsonDecode(raw) as Map;
      return decoded['enabled'] as bool? ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Synchronous version of loadPromoCodesConfig
  bool loadPromoCodesConfigSync() {
    if (!_initialized) return true;
    try {
      final raw = _getAppConfigBox().get('promo_codes_enabled');
      if (raw == null || raw.isEmpty) return true;
      final decoded = jsonDecode(raw) as Map;
      return decoded['enabled'] as bool? ?? true;
    } catch (_) {
      return true;
    }
  }

  // ========== Sponsored Ads ==========
  Future<void> saveSponsoredAds(List<Map<String, dynamic>> ads) async {
    await _getSponsoredAdsBox().put('ads', jsonEncode(ads));
    await _updateLastSyncTime('sponsored_ads');
  }

  Future<void> clearSponsoredAds() async {
    await _getSponsoredAdsBox().delete('ads');
  }

  Future<List<Map<String, dynamic>>> loadSponsoredAds() async {
    final raw = _getSponsoredAdsBox().get('ads');
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Synchronous version of loadSponsoredAds
  List<Map<String, dynamic>> loadSponsoredAdsSync() {
    if (!_initialized) return [];
    try {
      final raw = _getSponsoredAdsBox().get('ads');
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSponsoredAdAnalytics(Map<String, dynamic> analytics) async {
    await _getSponsoredAdsBox().put('analytics', jsonEncode(analytics));
  }

  Future<Map<String, dynamic>?> loadSponsoredAdAnalytics() async {
    final raw = _getSponsoredAdsBox().get('analytics');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Synchronous version of loadSponsoredAdAnalytics
  Map<String, dynamic>? loadSponsoredAdAnalyticsSync() {
    if (!_initialized) return null;
    try {
      final raw = _getSponsoredAdsBox().get('analytics');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as Map;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  // ========== Ad Networks ==========
  Future<void> saveAdNetworks(List<Map<String, dynamic>> networks) async {
    await _getAdNetworksBox().put('networks', jsonEncode(networks));
    await _updateLastSyncTime('ad_networks');
  }

  Future<List<Map<String, dynamic>>> loadAdNetworks() async {
    final raw = _getAdNetworksBox().get('networks');
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // ========== Ad Units ==========
  Future<void> saveAdUnits(List<Map<String, dynamic>> units) async {
    await _getAdUnitsBox().put('units', jsonEncode(units));
    await _updateLastSyncTime('ad_units');
  }

  Future<List<Map<String, dynamic>>> loadAdUnits() async {
    final raw = _getAdUnitsBox().get('units');
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // ========== External Ads ==========
  Future<void> saveExternalAds(List<Map<String, dynamic>> ads) async {
    await _getExternalAdsBox().put('ads', jsonEncode(ads));
    await _updateLastSyncTime('external_ads');
  }

  Future<List<Map<String, dynamic>>> loadExternalAds() async {
    final raw = _getExternalAdsBox().get('ads');
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveExternalAdCampaigns(
    List<Map<String, dynamic>> campaigns,
  ) async {
    await _getExternalAdsBox().put('campaigns', jsonEncode(campaigns));
    await _updateLastSyncTime('external_ad_campaigns');
  }

  Future<List<Map<String, dynamic>>> loadExternalAdCampaigns() async {
    final raw = _getExternalAdsBox().get('campaigns');
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // ========== Ad Revenue ==========
  Future<void> saveAdRevenue(Map<String, dynamic> revenue) async {
    await _getAdRevenueBox().put('revenue', jsonEncode(revenue));
    await _updateLastSyncTime('ad_revenue');
  }

  Future<Map<String, dynamic>?> loadAdRevenue() async {
    final raw = _getAdRevenueBox().get('revenue');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Synchronous version of loadAdRevenue
  Map<String, dynamic>? loadAdRevenueSync() {
    if (!_initialized) return null;
    try {
      final raw = _getAdRevenueBox().get('revenue');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as Map;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Save external ad networks to local storage
  Future<void> saveExternalAdNetworks(
    List<Map<String, dynamic>> networks,
  ) async {
    await _getExternalAdsBox().put('networks', jsonEncode(networks));
    await _updateLastSyncTime('external_ad_networks');
  }

  /// Load external ad networks from local storage
  Future<List<Map<String, dynamic>>> loadExternalAdNetworks() async {
    final raw = _getExternalAdsBox().get('networks');
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Synchronous version of loadExternalAdNetworks
  List<Map<String, dynamic>> loadExternalAdNetworksSync() {
    if (!_initialized) return [];
    try {
      final raw = _getExternalAdsBox().get('networks');
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Save external ad dashboard analytics to local storage
  Future<void> saveExternalAdAnalytics(Map<String, dynamic> analytics) async {
    await _getExternalAdsBox().put('analytics', jsonEncode(analytics));
    await _updateLastSyncTime('external_ad_analytics');
  }

  /// Load external ad dashboard analytics from local storage
  Future<Map<String, dynamic>> loadExternalAdAnalytics() async {
    final raw = _getExternalAdsBox().get('analytics');
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded;
    } catch (_) {
      return {};
    }
  }

  /// Synchronous version of loadExternalAdAnalytics
  Map<String, dynamic> loadExternalAdAnalyticsSync() {
    if (!_initialized) return {};
    try {
      final raw = _getExternalAdsBox().get('analytics');
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded;
    } catch (_) {
      return {};
    }
  }

  /// Save external ad drill-down data to local storage
  Future<void> saveExternalAdDrilldown(
    String type,
    List<Map<String, dynamic>> data,
  ) async {
    await _getExternalAdsBox().put('drilldown_$type', jsonEncode(data));
    await _updateLastSyncTime('external_ad_drilldown_$type');
  }

  /// Load external ad drill-down data from local storage
  Future<List<Map<String, dynamic>>> loadExternalAdDrilldown(
    String type,
  ) async {
    final raw = _getExternalAdsBox().get('drilldown_$type');
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Synchronous version of loadExternalAdDrilldown
  List<Map<String, dynamic>> loadExternalAdDrilldownSync(String type) {
    if (!_initialized) return [];
    try {
      final raw = _getExternalAdsBox().get('drilldown_$type');
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Save analytics cache (multiple date ranges) to persistent storage
  Future<void> saveSponsoredAdAnalyticsCache(
    Map<String, Map<String, dynamic>> cacheEntries,
  ) async {
    await _getSponsoredAdsBox().put(
      'analytics_cache',
      jsonEncode(cacheEntries),
    );
  }

  /// Load analytics cache from persistent storage
  Future<Map<String, Map<String, dynamic>>>
  loadSponsoredAdAnalyticsCache() async {
    final raw = _getSponsoredAdsBox().get('analytics_cache');
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (key, value) => MapEntry(key, Map<String, dynamic>.from(value as Map)),
      );
    } catch (_) {
      return {};
    }
  }

  /// Synchronous version of loadSponsoredAdAnalyticsCache
  Map<String, Map<String, dynamic>> loadSponsoredAdAnalyticsCacheSync() {
    if (!_initialized) return {};
    try {
      final raw = _getSponsoredAdsBox().get('analytics_cache');
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (key, value) => MapEntry(key, Map<String, dynamic>.from(value as Map)),
      );
    } catch (_) {
      return {};
    }
  }

  /// Save external ads analytics cache (multiple date ranges) to persistent storage
  Future<void> saveExternalAdAnalyticsCache(
    Map<String, Map<String, dynamic>> cacheEntries,
  ) async {
    await _getExternalAdsBox().put('analytics_cache', jsonEncode(cacheEntries));
  }

  /// Load external ads analytics cache from persistent storage
  Future<Map<String, Map<String, dynamic>>>
  loadExternalAdAnalyticsCache() async {
    final raw = _getExternalAdsBox().get('analytics_cache');
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (key, value) => MapEntry(key, Map<String, dynamic>.from(value as Map)),
      );
    } catch (_) {
      return {};
    }
  }

  /// Synchronous version of loadExternalAdAnalyticsCache
  Map<String, Map<String, dynamic>> loadExternalAdAnalyticsCacheSync() {
    if (!_initialized) return {};
    try {
      final raw = _getExternalAdsBox().get('analytics_cache');
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (key, value) => MapEntry(key, Map<String, dynamic>.from(value as Map)),
      );
    } catch (_) {
      return {};
    }
  }

  // ========== Dashboard Stats ==========
  Future<void> saveDashboard(
    Map<String, dynamic> stats, {
    String window = '24h',
  }) async {
    await _getDashboardBox().put('stats_$window', jsonEncode(stats));
    await _updateLastSyncTime('dashboard');
  }

  Future<Map<String, dynamic>?> loadDashboard({String window = '24h'}) async {
    final raw = _getDashboardBox().get('stats_$window');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Synchronous version of loadDashboard for immediate UI rendering
  Map<String, dynamic>? loadDashboardSync({String window = '24h'}) {
    if (!_initialized) return null;
    try {
      final raw = _getDashboardBox().get('stats_$window');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as Map;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  // ========== Generic Section Data ==========
  Future<void> saveSectionData(
    String sectionKey,
    List<Map<String, dynamic>> data,
  ) async {
    await _getSectionsBox().put(sectionKey, jsonEncode(data));
    await _updateLastSyncTime('section_$sectionKey');
  }

  Future<List<Map<String, dynamic>>> loadSectionData(String sectionKey) async {
    final raw = _getSectionsBox().get(sectionKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSectionDataMap(
    String sectionKey,
    Map<String, dynamic> data,
  ) async {
    await _getSectionsBox().put(sectionKey, jsonEncode(data));
    await _updateLastSyncTime('section_$sectionKey');
  }

  Future<Map<String, dynamic>?> loadSectionDataMap(String sectionKey) async {
    final raw = _getSectionsBox().get(sectionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Synchronous version of loadSectionData
  List<Map<String, dynamic>> loadSectionDataSync(String sectionKey) {
    if (!_initialized) return [];
    try {
      final raw = _getSectionsBox().get(sectionKey);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // ========== Metadata / Sync Tracking ==========
  Future<void> _updateLastSyncTime(String dataType) async {
    final timestamp = DateTime.now().toIso8601String();
    await _getMetadataBox().put('last_sync_$dataType', timestamp);
  }

  Future<DateTime?> getLastSyncTime(String dataType) async {
    final raw = _getMetadataBox().get('last_sync_$dataType');
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  // ========== Box Getters ==========
  Box<String> _getPromoCodesBox() {
    if (_promoCodesBox == null) {
      throw StateError('AdminLocalDbService not initialized');
    }
    return _promoCodesBox!;
  }

  Box<String> _getAppConfigBox() {
    if (_appConfigBox == null) {
      throw StateError('AdminLocalDbService not initialized');
    }
    return _appConfigBox!;
  }

  Box<String> _getSponsoredAdsBox() {
    if (_sponsoredAdsBox == null) {
      throw StateError('AdminLocalDbService not initialized');
    }
    return _sponsoredAdsBox!;
  }

  Box<String> _getAdNetworksBox() {
    if (_adNetworksBox == null) {
      throw StateError('AdminLocalDbService not initialized');
    }
    return _adNetworksBox!;
  }

  Box<String> _getAdUnitsBox() {
    if (_adUnitsBox == null) {
      throw StateError('AdminLocalDbService not initialized');
    }
    return _adUnitsBox!;
  }

  Box<String> _getExternalAdsBox() {
    if (_externalAdsBox == null) {
      throw StateError('AdminLocalDbService not initialized');
    }
    return _externalAdsBox!;
  }

  Box<String> _getAdRevenueBox() {
    if (_adRevenueBox == null) {
      throw StateError('AdminLocalDbService not initialized');
    }
    return _adRevenueBox!;
  }

  Box<String> _getDashboardBox() {
    if (_dashboardBox == null) {
      throw StateError('AdminLocalDbService not initialized');
    }
    return _dashboardBox!;
  }

  Box<String> _getMetadataBox() {
    if (_metadataBox == null) {
      throw StateError('AdminLocalDbService not initialized');
    }
    return _metadataBox!;
  }

  Box<String> _getSectionsBox() {
    if (_sectionsBox == null) {
      throw StateError('AdminLocalDbService not initialized');
    }
    return _sectionsBox!;
  }

  // ========== Clear All Data ==========
  Future<void> clearAll() async {
    await Future.wait([
      if (_promoCodesBox != null) _promoCodesBox!.clear(),
      if (_appConfigBox != null) _appConfigBox!.clear(),
      if (_sponsoredAdsBox != null) _sponsoredAdsBox!.clear(),
      if (_adNetworksBox != null) _adNetworksBox!.clear(),
      if (_adUnitsBox != null) _adUnitsBox!.clear(),
      if (_externalAdsBox != null) _externalAdsBox!.clear(),
      if (_adRevenueBox != null) _adRevenueBox!.clear(),
      if (_dashboardBox != null) _dashboardBox!.clear(),
      if (_metadataBox != null) _metadataBox!.clear(),
      if (_sectionsBox != null) _sectionsBox!.clear(),
    ]);
  }

  // ========== Unified Ad Settings ==========
  Future<void> saveUnifiedAdSettings(Map<String, dynamic> settings) async {
    await _getAppConfigBox().put('unified_ad_settings', jsonEncode(settings));
    await _updateLastSyncTime('unified_ad_settings');
  }

  Map<String, dynamic>? loadUnifiedAdSettingsSync() {
    if (!_initialized) return null;
    try {
      final raw = _getAppConfigBox().get('unified_ad_settings');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as Map;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> loadUnifiedAdSettings() async {
    final raw = _getAppConfigBox().get('unified_ad_settings');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  // ========== Cache Stats ==========
  Future<Map<String, dynamic>> getCacheStats() async {
    final stats = <String, dynamic>{};

    final promoCodes = await loadPromoCodes();
    stats['promoCodes'] = promoCodes.length;

    final sponsoredAds = await loadSponsoredAds();
    stats['sponsoredAds'] = sponsoredAds.length;

    final adNetworks = await loadAdNetworks();
    stats['adNetworks'] = adNetworks.length;

    final adUnits = await loadAdUnits();
    stats['adUnits'] = adUnits.length;

    final externalAds = await loadExternalAds();
    stats['externalAds'] = externalAds.length;

    final externalCampaigns = await loadExternalAdCampaigns();
    stats['externalCampaigns'] = externalCampaigns.length;

    stats['lastSyncTimes'] = {
      'promo_codes': (await getLastSyncTime('promo_codes'))?.toIso8601String(),
      'app_config': (await getLastSyncTime('app_config'))?.toIso8601String(),
      'sponsored_ads': (await getLastSyncTime(
        'sponsored_ads',
      ))?.toIso8601String(),
      'ad_networks': (await getLastSyncTime('ad_networks'))?.toIso8601String(),
      'ad_units': (await getLastSyncTime('ad_units'))?.toIso8601String(),
      'external_ads': (await getLastSyncTime(
        'external_ads',
      ))?.toIso8601String(),
      'external_ad_campaigns': (await getLastSyncTime(
        'external_ad_campaigns',
      ))?.toIso8601String(),
      'ad_revenue': (await getLastSyncTime('ad_revenue'))?.toIso8601String(),
    };

    return stats;
  }
}
