// lib/screens/external_ads_dashboard.dart
// Admin dashboard for managing external ad system (Google Mobile Ads/AdMob)

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/admin_local_db_service.dart';
import '../services/admin_offline_cache_manager.dart';

// Type definitions
typedef AdminTextLookup =
    String Function(String key, {Map<String, String>? params});

typedef ConfigPayload = Map<String, dynamic>;

/// Admin dashboard for managing external ad system
class AdminExternalAdsDashboard extends StatefulWidget {
  const AdminExternalAdsDashboard({
    super.key,
    required this.t,
    required this.localeCode,
    required this.textDirection,
  });

  final AdminTextLookup t;
  final String localeCode;
  final TextDirection textDirection;

  @override
  State<AdminExternalAdsDashboard> createState() =>
      _AdminExternalAdsDashboardState();
}

class _AdminExternalAdsDashboardState extends State<AdminExternalAdsDashboard>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  String t(String key, {Map<String, String>? params}) =>
      widget.t(key, params: params);
  static const _tabCount = 3;

  TabController? _tabController;
  Future<_ExternalAdConfigState>? _adConfigFuture;
  Future<_ExternalAdsDashboardData>? _dashboardFuture;
  Future<List<_ExternalAdNetwork>>? _networksFuture;
  bool _configHydrated = false;
  bool _serverConfigHydrated = false;
  bool _isHandlingTabTransition = false;
  bool _isSubscribed = false;
  final List<StreamSubscription<List<Map<String, dynamic>>>?> _realtimeSubs =
      [];
  StreamSubscription<bool>? _availabilitySub;
  Timer? _dashboardReloadDebounce;

  @override
  bool get wantKeepAlive => true;

  // Cached data
  _ExternalAdConfigState? _cachedConfig;
  _ExternalAdsDashboardData? _cachedDashboard;
  List<_ExternalAdNetwork>? _cachedNetworks;

  // Smart analytics cache: stores fetched data with their date ranges
  // Key: cache identifier (preset or custom range string)
  // Value: (data, startUtc, endUtc)
  final Map<
    String,
    ({_ExternalAdsDashboardData data, DateTime startUtc, DateTime endUtc})
  >
  _analyticsCache = {};

  // Config state
  bool _externalAdsEnabled = false;
  String _displayOrder = 'external_first';
  bool _isSavingConfig = false;
  Map<String, bool> _placementsEnabled = {};
  Map<String, bool> _tiersEnabled = {};
  Map<String, bool> _platformsEnabled = {};
  Map<String, int?> _rateLimitConfigs = {};
  final _originalValues = _ExternalAdConfigOriginals();

  // Drill-down state
  String? _selectedDrilldown;
  bool _isLoadingDrilldown = false;
  List<Map<String, dynamic>>? _drilldownData;

  // Analytics date-range state
  // Preset codes: '7d' | '30d' | '90d' | 'all' | 'custom'
  String _rangePreset = '30d';
  DateTime? _customStart; // local time
  DateTime? _customEnd; // local time

  // Controllers
  final _perUserController = TextEditingController();
  final _perHourController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCachedDataSync();
    _primeFutures();
    _ensureTabController();
    _setupRealtimeSubscription();

    // Re-establish realtime subscriptions when connectivity is restored.
    // The stream channels don't survive an offline→online transition (the
    // realtime client doesn't rejoin them), so tear down and re-create.
    _availabilitySub = adminOfflineCacheManager.availabilityStream.listen((
      available,
    ) {
      if (!mounted) return;
      if (available) {
        _teardownRealtimeSubscriptions();
        _setupRealtimeSubscription();
      }
    });
  }

  void _loadCachedDataSync() {
    try {
      final localDb = AdminLocalDbService.shared;

      // Load config synchronously
      final cachedConfig = localDb.loadAppConfigSync();
      if (cachedConfig != null && cachedConfig.isNotEmpty) {
        _cachedConfig = _buildConfigStateFromMap(cachedConfig);
        _configHydrated = true;
        _externalAdsEnabled = _cachedConfig!.isEnabled;
        _displayOrder = _cachedConfig!.displayOrder;
        _placementsEnabled = {..._cachedConfig!.placementsEnabled};
        _tiersEnabled = {..._cachedConfig!.tiersEnabled};
        _platformsEnabled = {..._cachedConfig!.platformsEnabled};
        _rateLimitConfigs = {..._cachedConfig!.rateLimitConfigs};
        _perUserController.text =
            _rateLimitConfigs['per_user']?.toString() ?? '';
        _perHourController.text =
            _rateLimitConfigs['per_hour']?.toString() ?? '';
        _captureOriginalValues();
      }

      // Load networks synchronously
      final cachedNetworks = localDb.loadExternalAdNetworksSync();
      if (cachedNetworks.isNotEmpty) {
        _cachedNetworks = cachedNetworks
            .map((n) => _ExternalAdNetwork.fromMap(n))
            .toList();
      }

      // Load dashboard analytics synchronously for immediate display
      final cachedAnalytics = localDb.loadExternalAdAnalyticsSync();
      if (cachedAnalytics.isNotEmpty) {
        _cachedDashboard = _parseDashboardFromCache(cachedAnalytics);
      } else {
        _cachedDashboard = const _ExternalAdsDashboardData.empty();
      }

      // Load persisted analytics cache (all date ranges)
      final persistedCache = localDb.loadExternalAdAnalyticsCacheSync();
      if (persistedCache.isNotEmpty) {
        _restoreAnalyticsCacheFromPersisted(persistedCache);
        debugPrint(
          '[ExternalAds] Restored ${_analyticsCache.length} cached date ranges from storage',
        );
      }

      // Load cached drill-down data (By Network, By Placement, By Platform)
      // so analytics tables display immediately without waiting for server fetch
      final cachedNetwork = localDb.loadExternalAdDrilldownSync('network');
      final cachedPlacement = localDb.loadExternalAdDrilldownSync('placement');
      final cachedPlatform = localDb.loadExternalAdDrilldownSync('platform');
      if (cachedNetwork.isNotEmpty) {
        _selectedDrilldown = 'network';
        _drilldownData = cachedNetwork;
      } else if (cachedPlacement.isNotEmpty) {
        _selectedDrilldown = 'placement';
        _drilldownData = cachedPlacement;
      } else if (cachedPlatform.isNotEmpty) {
        _selectedDrilldown = 'platform';
        _drilldownData = cachedPlatform;
      }
    } catch (_) {}
  }

  /// Parse dashboard data from cached analytics
  _ExternalAdsDashboardData _parseDashboardFromCache(
    Map<String, dynamic> analytics,
  ) {
    final eventsList = (analytics['events'] as List<dynamic>?) ?? [];
    final events = eventsList
        .map(
          (e) => _ExternalAdEventRow(
            eventType: e['event_type'] ?? 'unknown',
            placement: e['placement'] ?? 'unknown',
            userId: e['user_id'] ?? 'unknown',
            createdAt: e['created_at'] != null
                ? DateTime.tryParse(e['created_at'])
                : null,
            clickCount: e['click_count'] ?? 0,
          ),
        )
        .toList();

    return _ExternalAdsDashboardData(
      totalImpressions: analytics['total_impressions'] ?? 0,
      totalClicks: analytics['total_clicks'] ?? 0,
      ctrPercent: (analytics['ctr_percent'] ?? 0.0).toDouble(),
      campaignCount: analytics['campaign_count'] ?? 0,
      eventCount: analytics['event_count'] ?? events.length,
      events: events,
      lastImpressionAt: DateTime.tryParse(
        (analytics['last_impression_at'] ?? '').toString(),
      ),
      lastClickAt: DateTime.tryParse(
        (analytics['last_click_at'] ?? '').toString(),
      ),
    );
  }

  void _primeFutures() {
    _adConfigFuture ??= _loadAdConfig().then((data) {
      if (mounted) {
        setState(() {
          _cachedConfig = data;
          _hydrateConfig(data);
        });
      }
      return data;
    });
    _dashboardFuture ??= _loadDashboardData().then((data) {
      if (mounted) setState(() => _cachedDashboard = data);
      return data;
    });
    _networksFuture ??= _loadNetworks().then((data) {
      if (mounted) setState(() => _cachedNetworks = data);
      return data;
    });
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _serverConfigHydrated = false;
      _cachedConfig = null;
      _cachedNetworks = null;
      _adConfigFuture = null;
      _dashboardFuture = null;
      _networksFuture = null;
    });
    _primeFutures();
    await _adConfigFuture;
  }

  /// Debounced dashboard-only reload (used by the date-range selector).
  /// When [clearCache] is true, cached analytics + drill-down state is
  /// discarded so the new range fetches fresh data.
  void _scheduleDashboardReload({bool clearCache = false}) {
    if (!mounted) return;
    _dashboardReloadDebounce?.cancel();
    _dashboardReloadDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;

      // Always clear drill-down when changing date filters (it's date-specific)
      _drilldownData = null;
      // Keep the selected drill-down type so it reloads for the new date range
      // _selectedDrilldown stays the same

      if (clearCache) {
        _analyticsCache.clear();
        _persistAnalyticsCache(); // Persist the cleared cache
      }
      setState(() {
        _dashboardFuture = null;
      });
      _dashboardFuture ??= _loadDashboardData().then((data) {
        if (mounted) setState(() => _cachedDashboard = data);
        return data;
      });

      // Reload drill-down data for the new date range if one was selected
      if (_selectedDrilldown != null) {
        _loadDrilldownData(_selectedDrilldown!, silent: true);
      }

      setState(() {});
    });
  }

  void _ensureTabController() {
    if (_tabController != null) return;
    _tabController = TabController(length: _tabCount, vsync: this);
    _tabController!.addListener(_handleTabControllerChanged);
  }

  void _handleTabControllerChanged() {
    if (_isHandlingTabTransition || !_tabController!.indexIsChanging) return;
    _isHandlingTabTransition = true;
    // Tab transition handling logic here if needed
    _isHandlingTabTransition = false;
  }

  @override
  void reassemble() {
    super.reassemble();
    // Don't clear futures - they should persist when app comes to foreground
    // Only clear config hydrated flags to allow config updates if needed
    _configHydrated = false;
    _serverConfigHydrated = false;
  }

  @override
  void dispose() {
    _availabilitySub?.cancel();
    _teardownRealtimeSubscriptions();
    _dashboardReloadDebounce?.cancel();
    _tabController?.removeListener(_handleTabControllerChanged);
    _tabController?.dispose();
    _perUserController.dispose();
    _perHourController.dispose();
    super.dispose();
  }

  void _setupRealtimeSubscription() {
    // Skip realtime subscriptions when offline to avoid noisy connection
    // errors — the availability listener below re-runs this when Supabase
    // is reachable again.
    if (adminOfflineCacheManager.shouldUseCachedData()) {
      return;
    }
    if (_isSubscribed) return;
    _isSubscribed = true;
    try {
      // Suppress noisy realtime error logs when the device is offline.
      void logRealtimeError(String label, Object error) {
        if (!adminOfflineCacheManager.shouldUseCachedData()) {
          debugPrint('[ExternalAds] $label realtime error: $error');
        }
      }

      // Listen to app_config changes (ad settings)
      _realtimeSubs.add(
        Supabase.instance.client
            .from('app_config')
            .stream(primaryKey: ['config_key'])
            .listen((data) {
              debugPrint('[ExternalAds] app_config realtime update received');
              if (mounted) _refresh();
            }, onError: (error) => logRealtimeError('app_config', error)),
      );

      // Listen to ad_revenue_events changes (analytics updates)
      _realtimeSubs.add(
        Supabase.instance.client
            .from('ad_revenue_events')
            .stream(primaryKey: ['id'])
            .listen(
              (data) {
                debugPrint(
                  '[ExternalAds] ad_revenue_events realtime update received: ${data.length} records',
                );
                // Clear local cache to ensure fresh data on mobile
                _clearLocalCache();
                // Apply local increment for immediate UI update (no full reload)
                if (mounted) {
                  _applyRevenueEventIncrement(
                    data.cast<Map<String, dynamic>>(),
                  );
                }
              },
              onError: (error) {
                debugPrint(
                  '[ExternalAds] ad_revenue_events realtime error: $error',
                );
              },
            ),
      );

      // Listen to ad_networks changes (network status updates)
      _realtimeSubs.add(
        Supabase.instance.client
            .from('ad_networks')
            .stream(primaryKey: ['id'])
            .listen(
              (data) {
                debugPrint('[ExternalAds] ad_networks realtime update received');
                if (mounted) {
                  _networksFuture = _loadNetworks();
                  setState(() {});
                }
              },
              onError: (error) {
                debugPrint(
                  '[ExternalAds] ad_networks realtime error: $error',
                );
              },
            ),
      );

      debugPrint('[ExternalAds] Realtime subscriptions established');
    } catch (e, stackTrace) {
      debugPrint('[ExternalAds] Failed to setup realtime subscriptions: $e');
      debugPrint('[ExternalAds] StackTrace: $stackTrace');
    }
  }

  /// Cancel the stream subscriptions so they can be re-created after an
  /// offline→online cycle. The realtime client does not rejoin stream
  /// channels after a socket disconnect, and re-subscribing without
  /// cancelling would accumulate duplicate channels.
  void _teardownRealtimeSubscriptions() {
    for (final sub in _realtimeSubs) {
      try {
        sub?.cancel();
      } catch (_) {}
    }
    _realtimeSubs.clear();
    _isSubscribed = false;
  }

  // ==================== BUILD ====================
  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = widget.t;
    final theme = Theme.of(context);
    final tabController = _safeTabController;

    return Directionality(
      textDirection: widget.textDirection,
      child: Column(
        children: [
          // Rounded tab container matching internal system UI
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: TabBar(
                controller: tabController,
                isScrollable: true,
                dividerColor: Colors.transparent,
                padding: EdgeInsets.zero,
                labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                labelColor: theme.colorScheme.onSurface,
                unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
                tabs: [
                  Tab(
                    icon: const Icon(Icons.insights_outlined),
                    text: t('adminSponsoredAdsAnalyticsTitle'),
                  ),
                  Tab(
                    icon: const Icon(Icons.tune_outlined),
                    text: t('adminSponsoredAdsConfigTitle'),
                  ),
                  Tab(
                    icon: const Icon(Icons.view_list_outlined),
                    text: t('adminExternalAdsMetricActiveNetworks'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: TabBarView(
              controller: tabController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildAnalyticsTab(context),
                _buildControlsTab(context),
                _buildCampaignsTab(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  TabController get _safeTabController {
    _ensureTabController();
    return _tabController!;
  }

  Future<_ExternalAdsDashboardData> get _safeDashboardFuture {
    return _dashboardFuture ??= _loadDashboardData().then((data) {
      if (mounted) setState(() => _cachedDashboard = data);
      return data;
    });
  }

  ({DateTime startUtc, DateTime endUtc}) _analyticsWindowUtc() {
    // Preset ranges: last N days through end of today (local → UTC).
    if (_rangePreset == '7d' ||
        _rangePreset == '30d' ||
        _rangePreset == '90d') {
      final days = int.parse(_rangePreset.replaceAll('d', ''));
      final nowLocal = DateTime.now();
      final startOfTodayLocal = DateTime(
        nowLocal.year,
        nowLocal.month,
        nowLocal.day,
      );
      final startUtc = startOfTodayLocal
          .subtract(Duration(days: days - 1))
          .toUtc();
      final endUtc = startOfTodayLocal
          .add(const Duration(days: 1))
          .subtract(const Duration(microseconds: 1))
          .toUtc();
      return (startUtc: startUtc, endUtc: endUtc);
    }

    // All time: a sentinel start (epoch) through now.
    if (_rangePreset == 'all') {
      final startUtc = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      final endUtc = DateTime.now().toUtc();
      return (startUtc: startUtc, endUtc: endUtc);
    }

    // Custom: from the picked From/To (local → UTC). Inclusive end of day.
    final startLocal = _customStart;
    final endLocal = _customEnd;
    if (startLocal != null && endLocal != null) {
      final startUtc = startLocal.toUtc();
      final endUtc = endLocal
          .add(const Duration(days: 1))
          .subtract(const Duration(microseconds: 1))
          .toUtc();
      return (startUtc: startUtc, endUtc: endUtc);
    }

    // Fallback (custom range not fully set): last 30 days.
    final nowLocal = DateTime.now();
    final startOfTodayLocal = DateTime(
      nowLocal.year,
      nowLocal.month,
      nowLocal.day,
    );
    final startUtc = startOfTodayLocal
        .subtract(const Duration(days: 29))
        .toUtc();
    final endUtc = startOfTodayLocal
        .add(const Duration(days: 1))
        .subtract(const Duration(microseconds: 1))
        .toUtc();
    return (startUtc: startUtc, endUtc: endUtc);
  }

  /// A short, cache-safe key fragment describing the active range.
  String get _rangeCacheKey {
    switch (_rangePreset) {
      case 'all':
        return 'all';
      case 'custom':
        final s = _customStart?.toIso8601String() ?? 'na';
        final e = _customEnd?.toIso8601String() ?? 'na';
        return 'custom_${s}_$e';
      default:
        return _rangePreset;
    }
  }

  /// Track last processed event ID to avoid counting initial sync as new
  final Set<String> _processedEventIds = <String>{};
  bool _hasProcessedInitialRevenueSnapshot = false;

  /// Apply ad_revenue_events increment locally for immediate UI update (no full reload)
  void _applyRevenueEventIncrement(List<Map<String, dynamic>> records) {
    if (!_hasProcessedInitialRevenueSnapshot) {
      // First event from the realtime subscription is the initial snapshot of ALL
      // existing records. These are already counted in the dashboard data, so just
      // track their IDs to prevent double-counting, regardless of _cachedDashboard state.
      for (final record in records) {
        final id = (record['id'] ?? '').toString();
        if (id.isNotEmpty) _processedEventIds.add(id);
      }
      _hasProcessedInitialRevenueSnapshot = true;
      debugPrint(
        '[ExternalAds] Initial snapshot: tracked ${records.length} existing events',
      );
      return;
    }

    final current = _cachedDashboard;
    if (current == null) return;

    var impressionsAdded = 0;
    var clicksAdded = 0;
    final newEvents = <_ExternalAdEventRow>[];

    for (final record in records) {
      final id = (record['id'] ?? '').toString();
      if (id.isEmpty) continue;

      // Skip if we've already processed this record
      if (_processedEventIds.contains(id)) continue;
      _processedEventIds.add(id);

      final eventType = (record['event_type'] ?? '').toString();
      final clickCount = (record['click_count'] as num?)?.toInt() ?? 0;

      if (eventType == 'impression') {
        impressionsAdded++;
      } else if (eventType == 'click' || clickCount > 0) {
        clicksAdded++;
      }

      // Build new event row for the list
      newEvents.add(
        _ExternalAdEventRow(
          eventType: eventType,
          placement: (record['placement'] ?? 'unknown').toString(),
          userId: (record['user_id'] ?? 'unknown').toString(),
          createdAt: record['created_at'] != null
              ? DateTime.tryParse(record['created_at'].toString())
              : null,
          clickCount: clickCount,
        ),
      );
    }

    if ((impressionsAdded > 0 || clicksAdded > 0) && mounted) {
      final totalImpressions = current.totalImpressions + impressionsAdded;
      final totalClicks = current.totalClicks + clicksAdded;
      final ctrPercent = totalImpressions > 0
          ? (totalClicks / totalImpressions) * 100
          : 0.0;

      // Add new events to the beginning of the list, keep only latest 10
      final updatedEvents = [...newEvents, ...current.events].take(10).toList();

      debugPrint(
        '[ExternalAds] Applied $impressionsAdded NEW impressions, $clicksAdded NEW clicks locally',
      );

      // Also update drilldown data so _effectiveDashboardData doesn't override with stale values
      final drilldown = _drilldownData;
      if (drilldown != null && drilldown.isNotEmpty) {
        // Update the first drilldown row (representing totals) with new counts
        final updatedDrilldown = drilldown
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
        if (updatedDrilldown.isNotEmpty) {
          updatedDrilldown[0]['impressions'] =
              (updatedDrilldown[0]['impressions'] as num? ?? 0) +
              impressionsAdded;
          updatedDrilldown[0]['clicks'] =
              (updatedDrilldown[0]['clicks'] as num? ?? 0) + clicksAdded;
          _drilldownData = updatedDrilldown;
          debugPrint('[ExternalAds] Updated drilldown data with new counts');
        }
      }

      setState(() {
        _cachedDashboard = _ExternalAdsDashboardData(
          totalImpressions: totalImpressions,
          totalClicks: totalClicks,
          ctrPercent: ctrPercent,
          campaignCount: current.campaignCount,
          eventCount: current.eventCount + records.length,
          events: updatedEvents,
        );
      });
    }
  }

  Future<void> _clearLocalCache() async {
    // In-memory state is already updated by _applyRevenueEventIncrement.
    // No need to wipe Hive cache — doing so would erase campaigns/config that
    // haven't been re-fetched yet, causing an empty spinner on next startup.
    debugPrint(
      '[ExternalAds] Skipping Hive cache clear (in-memory already incremented)',
    );
  }

  // ==================== ANALYTICS TAB ====================
  Widget _buildAnalyticsTab(BuildContext context) {
    final t = widget.t;

    // Hydrate config if needed (idempotent) - ensures _externalAdsEnabled is synced with _cachedConfig
    if (_cachedConfig != null && !_configHydrated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _hydrateConfig(_cachedConfig!);
      });
    }

    return FutureBuilder<_ExternalAdsDashboardData>(
      future: _safeDashboardFuture,
      builder: (context, snapshot) {
        // Prefer cached data (includes local realtime increments) over stale snapshot data
        final data = _effectiveDashboardData(_cachedDashboard ?? snapshot.data);

        if (snapshot.hasError &&
            data.totalImpressions == 0 &&
            data.events.isEmpty) {
          debugPrint('[ExternalAds] FutureBuilder error: ${snapshot.error}');
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(t('adminExternalAdsLoadError')),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _refresh,
                  child: Text(t('generalRetry')),
                ),
              ],
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!_externalAdsEnabled) _buildAdsDisabledBanner(),
            _buildAnalyticsSummary(context, data),
            const SizedBox(height: 24),
            _buildAnalyticsDrilldownSection(context),
            const SizedBox(height: 24),
            _buildEventsSection(context, data),
          ],
        );
      },
    );
  }

  Widget _buildAnalyticsSummary(
    BuildContext context,
    _ExternalAdsDashboardData data,
  ) {
    final t = widget.t;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t('adminSponsoredAdsAnalyticsTitle'),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        _buildDateRangeSelector(context),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final useFullRow = constraints.maxWidth >= 500;
            final itemWidth = useFullRow
                ? (constraints.maxWidth - 36) / 4
                : (constraints.maxWidth - 12) / 2;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _buildMetricCard(
                  context,
                  t('adminSponsoredAdsMetricImpressions'),
                  data.totalImpressions.toString(),
                  Icons.visibility_outlined,
                  width: itemWidth,
                  subtitle: data.lastImpressionAt == null
                      ? null
                      : t(
                          'adminSponsoredAdsMetricLastEventTime',
                          params: {
                            'time': _formatEventDateTime(
                              data.lastImpressionAt!,
                            ),
                          },
                        ),
                ),
                _buildMetricCard(
                  context,
                  t('adminSponsoredAdsMetricClicks'),
                  data.totalClicks.toString(),
                  Icons.ads_click_outlined,
                  width: itemWidth,
                  subtitle: data.lastClickAt == null
                      ? null
                      : t(
                          'adminSponsoredAdsMetricLastEventTime',
                          params: {
                            'time': _formatEventDateTime(data.lastClickAt!),
                          },
                        ),
                ),
                _buildMetricCard(
                  context,
                  t('adminExternalAdsMetricActiveNetworks'),
                  data.campaignCount.toString(),
                  Icons.network_cell_outlined,
                  width: itemWidth,
                ),
                _buildMetricCard(
                  context,
                  t('adminSponsoredAdsMetricCtr'),
                  '${data.ctrPercent.toStringAsFixed(2)}%',
                  Icons.trending_up_outlined,
                  width: itemWidth,
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// Date-range selector: 7d / 30d / 90d / All segmented control, plus a
  /// Custom button that opens From/To pickers.
  Widget _buildDateRangeSelector(BuildContext context) {
    final t = widget.t;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<String>(
              // The default selected checkmark eats ~24px inside the segment,
              // which is what wraps "30 days" onto a second row on
              // phone-width screens.
              showSelectedIcon: false,
              segments: [
                for (final entry in const {
                  '7d': 'adminAdsRange7d',
                  '30d': 'adminAdsRange30d',
                  '90d': 'adminAdsRange90d',
                  'all': 'adminAdsRangeAll',
                }.entries)
                  ButtonSegment(
                    value: entry.key,
                    label: Text(
                      t(entry.value),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              selected: _rangePreset == 'custom' ? <String>{} : {_rangePreset},
              onSelectionChanged: (value) {
                if (value.isEmpty) return;
                final next = value.first;
                if (next == _rangePreset) return;
                setState(() => _rangePreset = next);
                _scheduleDashboardReload(
                  clearCache: false,
                ); // Smart cache will handle reuse
              },
            ),
            OutlinedButton.icon(
              onPressed: _pickCustomRange,
              icon: Icon(
                _rangePreset == 'custom'
                    ? Icons.event_available
                    : Icons.date_range,
                size: 18,
              ),
              label: Text(
                _rangePreset == 'custom'
                    ? t('adminAdsRangeCustomApplied')
                    : t('adminAdsRangeCustom'),
              ),
              style: _rangePreset == 'custom'
                  ? OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.primary,
                      side: BorderSide(color: theme.colorScheme.primary),
                    )
                  : null,
            ),
          ],
        ),
        if (_rangePreset == 'custom' &&
            _customStart != null &&
            _customEnd != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_formatDateTime(_customStart!.toLocal())}  →  '
                  '${_formatDateTime(_customEnd!.toLocal())}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    _rangePreset = '30d';
                    _customStart = null;
                    _customEnd = null;
                  });
                  _scheduleDashboardReload(
                    clearCache: false,
                  ); // Smart cache will handle reuse
                },
                child: Text(t('adminAdsRangeClear')),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _pickCustomRange() async {
    final start = await _pickDateTime(
      initial: _customStart,
      first: DateTime(2020),
    );
    if (start == null || !mounted) return;
    final end = await _pickDateTime(initial: _customEnd ?? start, first: start);
    if (end == null || !mounted) return;
    setState(() {
      _rangePreset = 'custom';
      _customStart = start;
      _customEnd = end;
    });
    _scheduleDashboardReload(
      clearCache: false,
    ); // Smart cache will handle reuse
  }

  Future<DateTime?> _pickDateTime({DateTime? initial, DateTime? first}) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: first ?? DateTime(now.year - 2),
      lastDate: DateTime(now.year + 1),
      initialDate: initial?.toLocal() ?? now,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial?.toLocal() ?? now),
    );
    if (time == null || !mounted) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  /// Locale-aware short date+time for "Last event" subtitles.
  String _formatEventDateTime(DateTime dt) {
    final local = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} '
        '${two(local.hour > 12 ? local.hour - 12 : (local.hour == 0 ? 12 : local.hour))}:'
        '${two(local.minute)} '
        '${local.hour >= 12 ? 'PM' : 'AM'}';
  }

  _ExternalAdsDashboardData _effectiveDashboardData(
    _ExternalAdsDashboardData? fallback,
  ) {
    // Always return the original dashboard data
    // Drill-down data is only for the detail table, not for summary cards
    return fallback ?? const _ExternalAdsDashboardData.empty();
  }

  Widget _buildMetricCard(
    BuildContext context,
    String label,
    String value,
    IconData icon, {
    double? width,
    String? subtitle,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: width,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (subtitle != null && subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEventsSection(
    BuildContext context,
    _ExternalAdsDashboardData data,
  ) {
    final t = widget.t;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t('adminExternalAdsRecentEvents'),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        if (data.events.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  t('adminSponsoredAdsReportsEmpty'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                DataColumn(label: Text(t('adminExternalAdsEventType'))),
                DataColumn(label: Text(t('adminSponsoredAdsPlacement'))),
                DataColumn(label: Text(t('adminExternalAdsTimestamp'))),
                DataColumn(label: Text(t('adminExternalAdsUser'))),
              ],
              rows: data.events.take(10).map((event) {
                return DataRow(
                  cells: [
                    DataCell(Text(event.eventType)),
                    DataCell(Text(event.placement)),
                    DataCell(
                      Text(
                        event.createdAt != null
                            ? _formatDateTime(event.createdAt!)
                            : '-',
                      ),
                    ),
                    DataCell(Text(event.userId.substring(0, 8))),
                  ],
                );
              }).toList(),
            ),
          ),
      ],
    );
  }

  // ==================== ANALYTICS DRILL-DOWN ====================
  Widget _buildAnalyticsDrilldownSection(BuildContext context) {
    final t = widget.t;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('adminExternalAdsAnalytics'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: Text(t('adminExternalAdsAnalyticsByNetwork')),
                  selected: _selectedDrilldown == 'network',
                  onSelected: (selected) {
                    if (selected) _loadDrilldownData('network');
                  },
                ),
                ChoiceChip(
                  label: Text(t('adminExternalAdsAnalyticsByPlacement')),
                  selected: _selectedDrilldown == 'placement',
                  onSelected: (selected) {
                    if (selected) _loadDrilldownData('placement');
                  },
                ),
                ChoiceChip(
                  label: Text(t('adminExternalAdsAnalyticsByPlatform')),
                  selected: _selectedDrilldown == 'platform',
                  onSelected: (selected) {
                    if (selected) _loadDrilldownData('platform');
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_isLoadingDrilldown)
              const Center(child: CircularProgressIndicator())
            else if (_drilldownData != null)
              _buildDrilldownTable(context),
          ],
        ),
      ),
    );
  }

  Widget _buildDrilldownTable(BuildContext context) {
    final t = widget.t;

    final columns = [
      DataColumn(
        label: Text(
          _selectedDrilldown == 'network'
              ? t('adminExternalAdsMetricActiveNetworks')
              : _selectedDrilldown == 'placement'
              ? t('adminSponsoredAdsPlacement')
              : t('adminSponsoredAdsPlatform'),
        ),
      ),
      DataColumn(label: Text(t('adminSponsoredAdsMetricImpressions'))),
      DataColumn(label: Text(t('adminSponsoredAdsMetricClicks'))),
      DataColumn(label: Text(t('adminExternalAdsRevenue'))),
      DataColumn(label: Text(t('adminExternalAdsCtr'))),
      DataColumn(label: Text(t('adminExternalAdsCpm'))),
    ];

    final rows = _drilldownData!.map((row) {
      return DataRow(
        cells: [
          DataCell(
            Text(row['name'] ?? row['placement'] ?? row['platform'] ?? '-'),
          ),
          DataCell(Text((row['impressions'] ?? 0).toString())),
          DataCell(Text((row['clicks'] ?? 0).toString())),
          DataCell(Text('\$${(row['revenue_usd'] ?? 0.0).toStringAsFixed(2)}')),
          DataCell(Text('${(row['ctr_percent'] ?? 0.0).toStringAsFixed(2)}%')),
          DataCell(Text('\$${(row['cpm'] ?? 0.0).toStringAsFixed(2)}')),
        ],
      );
    }).toList();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(columns: columns, rows: rows),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')} '
        '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }

  // ==================== CONTROLS TAB ====================
  Widget _buildControlsTab(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [_buildAdConfigCard(context)],
    );
  }

  Widget _buildAdConfigCard(BuildContext context) {
    final t = widget.t;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _configHydrated
            ? _buildConfigContent(context)
            : FutureBuilder<_ExternalAdConfigState>(
                future: _adConfigFuture ?? _loadAdConfig(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }

                  if (snapshot.hasData) {
                    if (!_serverConfigHydrated) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          _hydrateConfig(snapshot.data!, fromServer: true);
                        }
                      });
                    }
                    if (_configHydrated) {
                      return _buildConfigContent(context);
                    }
                  }

                  if (snapshot.hasError && !_configHydrated) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('adminSponsoredAdsConfigLoadFailed')),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _refresh,
                          child: Text(t('generalRetry')),
                        ),
                      ],
                    );
                  }

                  return const SizedBox.shrink();
                },
              ),
      ),
    );
  }

  Widget _buildConfigContent(BuildContext context) {
    final t = widget.t;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!_externalAdsEnabled) _buildAdsDisabledBanner(),
        // Enable/Disable toggle
        SwitchListTile(
          title: Text(t('adminExternalAdsConfigEnabled')),
          subtitle: Text(t('adminExternalAdsMasterControlsSubtitle')),
          value: _externalAdsEnabled,
          onChanged: (value) {
            setState(() => _externalAdsEnabled = value);
          },
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 24),

        // Display order when both systems are enabled
        DropdownButtonFormField<String>(
          decoration: InputDecoration(
            labelText: t('adminAdDisplayOrderLabel'),
            border: const OutlineInputBorder(),
          ),
          initialValue: _displayOrder,
          items: [
            DropdownMenuItem(
              value: 'external_first',
              child: Text(t('adminAdDisplayOrderExternalFirst')),
            ),
            DropdownMenuItem(
              value: 'internal_first',
              child: Text(t('adminAdDisplayOrderInternalFirst')),
            ),
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() => _displayOrder = value);
            }
          },
        ),
        const SizedBox(height: 24),

        // Config sections
        if (_externalAdsEnabled) ...[
          ..._buildPlacementsSection(context),
          const SizedBox(height: 24),
          ..._buildTiersSection(context),
          const SizedBox(height: 24),
          ..._buildPlatformsSection(context),
          const SizedBox(height: 24),
          ..._buildRateLimitingSection(context),
          const SizedBox(height: 24),
        ],

        // Action buttons
        if (_hasChanges)
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton(
                onPressed: _isSavingConfig ? null : _cancelChanges,
                child: Text(t('generalCancel')),
              ),
              FilledButton(
                onPressed: _isSavingConfig ? null : _saveConfig,
                child: _isSavingConfig
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(t('generalSave')),
              ),
            ],
          ),
      ],
    );
  }

  List<Widget> _buildPlacementsSection(BuildContext context) {
    final t = widget.t;
    final placements = {
      'home_inline': 'adminSponsoredAdsPlacementHome',
      'matches_inline': 'adminSponsoredAdsPlacementMatches',
      'chats_inline': 'adminSponsoredAdsPlacementChatsInline',
      'events_inline': 'adminSponsoredAdsPlacementEventsInline',
      'profile_inline': 'adminSponsoredAdsPlacementProfileInline',
    };

    return [
      Text(
        t('adminExternalAdsPlacementConfigTitle'),
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        t('adminExternalAdsPlacementConfigSubtitle'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 8),
      ...placements.entries.map(
        (entry) => SwitchListTile(
          title: Text(t(entry.value)),
          value: _placementsEnabled[entry.key] ?? false,
          onChanged: (value) =>
              setState(() => _placementsEnabled[entry.key] = value),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    ];
  }

  List<Widget> _buildTiersSection(BuildContext context) {
    final t = widget.t;
    final tiers = {
      'free': 'adminSubscriptionTierFree',
      'plus': 'tierPlus',
      'gold': 'tierGold',
      'platinum': 'tierPlatinum',
    };

    return [
      Text(
        t('adminExternalAdsTierConfigTitle'),
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        t('adminExternalAdsTierConfigSubtitle'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 8),
      ...tiers.entries.map(
        (entry) => SwitchListTile(
          title: Text(t(entry.value)),
          value: _tiersEnabled[entry.key] ?? false,
          onChanged: (value) =>
              setState(() => _tiersEnabled[entry.key] = value),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    ];
  }

  List<Widget> _buildPlatformsSection(BuildContext context) {
    final t = widget.t;
    final platforms = {
      'android': 'adminSponsoredAdsPlatformAndroid',
      'ios': 'adminSponsoredAdsPlatformIos',
      'web': 'adminSponsoredAdsPlatformWeb',
    };

    return [
      Text(
        t('adminExternalAdsPlatformConfigTitle'),
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        t('adminExternalAdsPlatformConfigSubtitle'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 8),
      ...platforms.entries.map(
        (entry) => SwitchListTile(
          title: Text(t(entry.value)),
          value: _platformsEnabled[entry.key] ?? false,
          onChanged: (value) =>
              setState(() => _platformsEnabled[entry.key] = value),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    ];
  }

  List<Widget> _buildRateLimitingSection(BuildContext context) {
    final t = widget.t;

    return [
      Text(
        t('adminExternalAdsRateLimitingTitle'),
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        t('adminExternalAdsRateLimitingSubtitle'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 8),
      TextField(
        decoration: InputDecoration(
          labelText: t('adminExternalAdsRateLimitPerUser'),
          hintText: t('adminSponsoredAdsLeaveEmptyForNoLimit'),
          border: const OutlineInputBorder(),
        ),
        keyboardType: TextInputType.number,
        controller: _perUserController,
        onChanged: (text) => setState(() {
          _rateLimitConfigs['per_user'] = int.tryParse(text);
        }),
      ),
      const SizedBox(height: 12),
      TextField(
        decoration: InputDecoration(
          labelText: t('adminExternalAdsRateLimitPerHour'),
          hintText: t('adminSponsoredAdsLeaveEmptyForNoLimit'),
          border: const OutlineInputBorder(),
        ),
        keyboardType: TextInputType.number,
        controller: _perHourController,
        onChanged: (text) => setState(() {
          _rateLimitConfigs['per_hour'] = int.tryParse(text);
        }),
      ),
    ];
  }

  // ==================== CAMPAIGNS TAB ====================
  Widget _buildCampaignsTab(BuildContext context) {
    final t = widget.t;

    return FutureBuilder<List<_ExternalAdNetwork>>(
      future: _networksFuture ?? _loadNetworks(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            _cachedNetworks == null) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError && _cachedNetworks == null) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(t('adminExternalAdsLoadError')),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _refresh,
                  child: Text(t('generalRetry')),
                ),
              ],
            ),
          );
        }

        final networks = _cachedNetworks ?? snapshot.data ?? [];

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            if (!_externalAdsEnabled) _buildAdsDisabledBanner(),
            if (networks.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('adminExternalAdsNoNetworks')),
                      const SizedBox(height: 8),
                      Text(
                        t('adminExternalAdsConfigureNetworksHint'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              )
            else
              ...networks.map((network) => _buildNetworkCard(context, network)),
          ],
        );
      },
    );
  }

  Widget _buildAdsDisabledBanner() {
    final t = widget.t;
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      margin: const EdgeInsets.only(bottom: 16),
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            t('adminSponsoredAdsDisabledBannerTitle'),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNetworkCard(BuildContext context, _ExternalAdNetwork network) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        network.displayName,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        network.provider,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: network.isEnabled
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    network.isEnabled
                        ? t('adminExternalAdsActive')
                        : t('adminExternalAdsInactive'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: network.isEnabled
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${t('adminNetworkPriority')}: ${network.priority}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  // ==================== CONFIG MANAGEMENT ====================
  void _hydrateConfig(
    _ExternalAdConfigState config, {
    bool fromServer = false,
  }) {
    setState(() {
      _configHydrated = true;
      if (fromServer) _serverConfigHydrated = true;
      _externalAdsEnabled = config.isEnabled;
      _displayOrder = config.displayOrder;
      _placementsEnabled = {...config.placementsEnabled};
      _tiersEnabled = {...config.tiersEnabled};
      _platformsEnabled = {...config.platformsEnabled};
      _rateLimitConfigs = {...config.rateLimitConfigs};
    });
    _perUserController.text = _rateLimitConfigs['per_user']?.toString() ?? '';
    _perHourController.text = _rateLimitConfigs['per_hour']?.toString() ?? '';
    _captureOriginalValues();
  }

  bool get _hasChanges {
    return _externalAdsEnabled != _originalValues.isEnabled ||
        _displayOrder != _originalValues.displayOrder ||
        !_mapEquals(_placementsEnabled, _originalValues.placementsEnabled) ||
        !_mapEquals(_tiersEnabled, _originalValues.tiersEnabled) ||
        !_mapEquals(_platformsEnabled, _originalValues.platformsEnabled) ||
        !_mapEquals(_rateLimitConfigs, _originalValues.rateLimitConfigs);
  }

  void _captureOriginalValues() {
    _originalValues
      ..isEnabled = _externalAdsEnabled
      ..displayOrder = _displayOrder
      ..placementsEnabled = Map<String, bool>.from(_placementsEnabled)
      ..tiersEnabled = Map<String, bool>.from(_tiersEnabled)
      ..platformsEnabled = Map<String, bool>.from(_platformsEnabled)
      ..rateLimitConfigs = Map<String, int?>.from(_rateLimitConfigs);
  }

  void _cancelChanges() {
    setState(() {
      _externalAdsEnabled = _originalValues.isEnabled;
      _displayOrder = _originalValues.displayOrder;
      _placementsEnabled = Map<String, bool>.from(
        _originalValues.placementsEnabled,
      );
      _tiersEnabled = Map<String, bool>.from(_originalValues.tiersEnabled);
      _platformsEnabled = Map<String, bool>.from(
        _originalValues.platformsEnabled,
      );
      _rateLimitConfigs = Map<String, int?>.from(
        _originalValues.rateLimitConfigs,
      );
    });
    _perUserController.text = _rateLimitConfigs['per_user']?.toString() ?? '';
    _perHourController.text = _rateLimitConfigs['per_hour']?.toString() ?? '';
  }

  bool _mapEquals(Map a, Map b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }

  Future<void> _saveConfig() async {
    final t = widget.t;
    setState(() => _isSavingConfig = true);

    try {
      final supabase = Supabase.instance.client;

      // Prepare payloads
      final payloads = [
        _configPayload(key: 'ads.external.enabled', value: _externalAdsEnabled),
        _configPayload(key: 'ads.display_order', value: _displayOrder),
        _configPayload(
          key: 'ads.external.max_impressions_per_user_per_day',
          value: _rateLimitConfigs['per_user'],
        ),
        _configPayload(
          key: 'ads.external.max_impressions_per_user_per_hour',
          value: _rateLimitConfigs['per_hour'],
        ),
        _configPayload(
          key: 'ads.external.allowed_placements',
          value: _placementsEnabled.entries
              .where((e) => e.value)
              .map((e) => e.key)
              .toList(),
        ),
        _configPayload(
          key: 'ads.external.allowed_tiers',
          value: _tiersEnabled.entries
              .where((e) => e.value)
              .map((e) => e.key)
              .toList(),
        ),
        _configPayload(
          key: 'ads.external.allowed_platforms',
          value: _platformsEnabled.entries
              .where((e) => e.value)
              .map((e) => e.key)
              .toList(),
        ),
      ];

      // Save all configs
      for (final payload in payloads) {
        await supabase
            .from('app_config')
            .upsert(payload, onConflict: 'config_key');
      }

      // Clear local cache
      try {
        final localDb = await AdminLocalDbService.instance;
        await localDb.clearAppConfig();
      } catch (_) {}

      _showSuccess(t('adminSponsoredAdsConfigSaved'));
      unawaited(_touchAdConfig());
      await _refresh();
    } catch (e) {
      _showError('${t('adminSponsoredAdsConfigSaveFailed')} $e');
    } finally {
      if (mounted) {
        setState(() => _isSavingConfig = false);
      }
    }
  }

  /// Bump ads.config_version in app_config after every ad write so the
  /// MatchMe app hard-clears its ad caches in realtime instead of serving
  /// cached units until its debounce/reuse windows expire.
  Future<void> _touchAdConfig() async {
    try {
      await Supabase.instance.client.rpc('admin_touch_ad_config');
    } catch (e) {
      debugPrint('[ExternalAds] admin_touch_ad_config failed: $e');
    }
  }

  Map<String, dynamic> _configPayload({
    required String key,
    required Object? value,
  }) {
    final dynamic configValue;
    final String configType;
    if (value == null) {
      configValue = null;
      configType = 'null';
    } else if (value is List) {
      configValue = value;
      configType = 'array';
    } else if (value is bool) {
      configValue = value;
      configType = 'boolean';
    } else if (value is int) {
      configValue = value;
      configType = 'number';
    } else {
      configValue = value.toString();
      configType = 'string';
    }

    return {
      'config_key': key,
      'config_value': configValue,
      'config_type': configType,
      'category': 'ads',
      'description': 'Ad system configuration',
      'is_user_configurable': false,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  // ==================== DATA LOADING ====================

  /// Find cached analytics data that EXACTLY matches the requested date range.
  /// Returns null if no matching cached data exists.
  ({_ExternalAdsDashboardData data, DateTime startUtc, DateTime endUtc})?
  _findCachedAnalyticsCovering(DateTime requestedStart, DateTime requestedEnd) {
    // Look for cached entry with EXACT matching date range
    // Since Supabase returns aggregated counts for the specific range,
    // we cannot reuse broader ranges for narrower queries
    for (final entry in _analyticsCache.values) {
      // Check if dates match exactly
      // For "All" range, the start is always epoch (1970), so we use longer tolerance for end time
      final isEpochStart = requestedStart.millisecondsSinceEpoch == 0;
      final startMatch = isEpochStart
          ? entry.startUtc.millisecondsSinceEpoch == 0
          : entry.startUtc.difference(requestedStart).inSeconds.abs() < 1;

      // For "All" range (epoch start), allow 60 second tolerance on end time
      // since it uses DateTime.now() which changes constantly
      final endTolerance = isEpochStart ? 60 : 1;
      final endMatch =
          entry.endUtc.difference(requestedEnd).inSeconds.abs() < endTolerance;

      if (startMatch && endMatch) {
        // Invalidate cache entries that lack timestamps (cached by old code)
        if (entry.data.totalImpressions > 0 &&
            entry.data.lastImpressionAt == null) {
          debugPrint(
            '[ExternalAds] Cache entry lacks lastImpressionAt - forcing re-fetch',
          );
          return null;
        }
        if (entry.data.totalClicks > 0 && entry.data.lastClickAt == null) {
          debugPrint(
            '[ExternalAds] Cache entry lacks lastClickAt - forcing re-fetch',
          );
          return null;
        }
        debugPrint(
          '[ExternalAds] Found exact cached data for requested range (tolerance: ${endTolerance}s)',
        );
        return entry;
      }
    }
    return null;
  }

  /// Cache analytics data with its date range for exact reuse.
  void _cacheAnalyticsData(
    _ExternalAdsDashboardData data,
    DateTime startUtc,
    DateTime endUtc,
  ) {
    // Validate data before caching - don't cache obviously invalid data
    // (clicks without impressions is impossible for ad systems)
    if (data.totalClicks > 0 && data.totalImpressions == 0) {
      debugPrint(
        '[ExternalAds] Skipping cache of invalid data: ${data.totalImpressions} impressions, ${data.totalClicks} clicks',
      );
      return;
    }

    // Generate cache key based on the range
    final cacheKey = _generateCacheKey(startUtc, endUtc);

    // Store in cache
    _analyticsCache[cacheKey] = (
      data: data,
      startUtc: startUtc,
      endUtc: endUtc,
    );

    debugPrint(
      '[ExternalAds] Cached analytics data with key: $cacheKey (${_analyticsCache.length} entries)',
    );

    // Persist to storage asynchronously (don't wait)
    _persistAnalyticsCache();
  }

  /// Generate a cache key for a date range
  String _generateCacheKey(DateTime startUtc, DateTime endUtc) {
    // Use ISO strings for consistent key generation
    return '${startUtc.toIso8601String()}_${endUtc.toIso8601String()}';
  }

  /// Restore analytics cache from persisted data
  void _restoreAnalyticsCacheFromPersisted(
    Map<String, Map<String, dynamic>> persistedCache,
  ) {
    int skippedInvalid = 0;
    for (final entry in persistedCache.entries) {
      try {
        final data = entry.value;

        // Validate data before restoring - skip obviously invalid cached data
        final totalImpressions = data['totalImpressions'] ?? 0;
        final totalClicks = data['totalClicks'] ?? 0;
        if (totalClicks > 0 && totalImpressions == 0) {
          debugPrint(
            '[ExternalAds] Skipping invalid cached entry ${entry.key}: $totalImpressions impressions, $totalClicks clicks',
          );
          skippedInvalid++;
          continue;
        }

        final events =
            (data['events'] as List?)
                ?.map(
                  (e) => _ExternalAdEventRow(
                    eventType: e['event_type'] ?? 'unknown',
                    placement: e['placement'] ?? 'unknown',
                    userId: e['user_id'] ?? 'unknown',
                    createdAt: e['created_at'] != null
                        ? DateTime.parse(e['created_at'])
                        : null,
                    clickCount: e['click_count'] ?? 0,
                  ),
                )
                .toList() ??
            [];

        final dashboardData = _ExternalAdsDashboardData(
          totalImpressions: totalImpressions,
          totalClicks: totalClicks,
          ctrPercent: (data['ctrPercent'] ?? 0.0).toDouble(),
          campaignCount: data['campaignCount'] ?? 0,
          eventCount: data['eventCount'] ?? 0,
          events: events,
          lastImpressionAt: data['lastImpressionAt'] != null
              ? DateTime.parse(data['lastImpressionAt'])
              : null,
          lastClickAt: data['lastClickAt'] != null
              ? DateTime.parse(data['lastClickAt'])
              : null,
        );

        final startUtc = DateTime.parse(data['startUtc']);
        final endUtc = DateTime.parse(data['endUtc']);

        _analyticsCache[entry.key] = (
          data: dashboardData,
          startUtc: startUtc,
          endUtc: endUtc,
        );
      } catch (e) {
        debugPrint(
          '[ExternalAds] Failed to restore cache entry ${entry.key}: $e',
        );
      }
    }

    if (skippedInvalid > 0) {
      debugPrint(
        '[ExternalAds] Skipped $skippedInvalid invalid cached entries - will be removed from storage',
      );
      // Persist the cleaned cache (removes invalid entries from storage)
      _persistAnalyticsCache();
    }
  }

  /// Save analytics cache to persistent storage
  Future<void> _persistAnalyticsCache() async {
    try {
      final localDb = await AdminLocalDbService.instance;
      final persistedCache = <String, Map<String, dynamic>>{};

      for (final entry in _analyticsCache.entries) {
        persistedCache[entry.key] = {
          'startUtc': entry.value.startUtc.toIso8601String(),
          'endUtc': entry.value.endUtc.toIso8601String(),
          'totalImpressions': entry.value.data.totalImpressions,
          'totalClicks': entry.value.data.totalClicks,
          'ctrPercent': entry.value.data.ctrPercent,
          'campaignCount': entry.value.data.campaignCount,
          'eventCount': entry.value.data.eventCount,
          'lastImpressionAt': entry.value.data.lastImpressionAt
              ?.toIso8601String(),
          'lastClickAt': entry.value.data.lastClickAt?.toIso8601String(),
          'events': entry.value.data.events
              .map(
                (e) => {
                  'event_type': e.eventType,
                  'placement': e.placement,
                  'user_id': e.userId,
                  'created_at': e.createdAt?.toIso8601String(),
                  'click_count': e.clickCount,
                },
              )
              .toList(),
        };
      }

      await localDb.saveExternalAdAnalyticsCache(persistedCache);
      debugPrint(
        '[ExternalAds] Persisted ${persistedCache.length} cached date ranges to storage',
      );
    } catch (e) {
      debugPrint('[ExternalAds] Failed to persist analytics cache: $e');
    }
  }

  Future<_ExternalAdConfigState> _loadAdConfig() async {
    Map<String, dynamic>? cachedConfig;
    try {
      final localDb = await AdminLocalDbService.instance;
      cachedConfig = await localDb.loadAppConfig();
    } catch (_) {}

    // If offline and we have cached config, skip the server call entirely.
    if (adminOfflineCacheManager.shouldUseCachedData()) {
      if (cachedConfig != null) {
        return _buildConfigStateFromMap(cachedConfig);
      }
      throw Exception('No cached config available while offline');
    }

    try {
      final supabase = Supabase.instance.client;
      final configRows = await supabase
          .from('app_config')
          .select()
          .inFilter('config_key', [
            'ads.external.enabled',
            'ads.external.allowed_placements',
            'ads.external.allowed_tiers',
            'ads.external.allowed_platforms',
            'ads.external.max_impressions_per_user_per_day',
            'ads.external.max_impressions_per_user_per_hour',
            'ads.display_order',
          ])
          .timeout(const Duration(seconds: 10));

      final configMap = <String, dynamic>{};
      for (final row in configRows) {
        configMap[row['config_key'].toString()] = row['config_value'];
      }

      try {
        final localDb = await AdminLocalDbService.instance;
        await localDb.saveAppConfig(configMap);
      } catch (_) {}

      return _buildConfigStateFromMap(configMap);
    } catch (_) {
      if (cachedConfig != null) {
        return _buildConfigStateFromMap(cachedConfig);
      }
      rethrow;
    }
  }

  _ExternalAdConfigState _buildConfigStateFromMap(
    Map<String, dynamic> configMap,
  ) {
    final rawEnabled = configMap['ads.external.enabled'];
    final isEnabled = _parseBool(rawEnabled);
    final displayOrder = (configMap['ads.display_order'] ?? 'external_first')
        .toString()
        .toLowerCase();
    final safeDisplayOrder = displayOrder == 'internal_first'
        ? 'internal_first'
        : 'external_first';

    final placementsEnabled = <String, bool>{};
    final placementsJson = configMap['ads.external.allowed_placements'];
    if (placementsJson != null) {
      try {
        final List<dynamic> placements = placementsJson is List
            ? placementsJson
            : jsonDecode(placementsJson.toString());
        for (final p in [
          'home_inline',
          'matches_inline',
          'chats_inline',
          'events_inline',
          'profile_inline',
        ]) {
          placementsEnabled[p] = placements.contains(p);
        }
      } catch (e) {
        for (final p in [
          'home_inline',
          'matches_inline',
          'chats_inline',
          'events_inline',
          'profile_inline',
        ]) {
          placementsEnabled[p] = true;
        }
      }
    }

    final tiersEnabled = <String, bool>{};
    final tiersJson = configMap['ads.external.allowed_tiers'];
    if (tiersJson != null) {
      try {
        final List<dynamic> tiers = tiersJson is List
            ? tiersJson
            : jsonDecode(tiersJson.toString());
        for (final t in ['free', 'plus', 'gold', 'platinum']) {
          tiersEnabled[t] = tiers.contains(t);
        }
      } catch (e) {
        tiersEnabled['free'] = true;
      }
    }

    final platformsEnabled = <String, bool>{};
    final platformsJson = configMap['ads.external.allowed_platforms'];
    if (platformsJson != null) {
      try {
        final List<dynamic> platforms = platformsJson is List
            ? platformsJson
            : jsonDecode(platformsJson.toString());
        for (final p in ['android', 'ios', 'web']) {
          platformsEnabled[p] = platforms.contains(p);
        }
      } catch (e) {
        platformsEnabled['android'] = true;
        platformsEnabled['ios'] = true;
      }
    }

    final rateLimitConfigs = <String, int?>{
      'per_user': _parseInt(
        configMap['ads.external.max_impressions_per_user_per_day'],
      ),
      'per_hour': _parseInt(
        configMap['ads.external.max_impressions_per_user_per_hour'],
      ),
    };

    return _ExternalAdConfigState(
      isEnabled: isEnabled,
      displayOrder: safeDisplayOrder,
      placementsEnabled: placementsEnabled,
      tiersEnabled: tiersEnabled,
      platformsEnabled: platformsEnabled,
      rateLimitConfigs: rateLimitConfigs,
    );
  }

  bool _parseBool(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is String) return value.toLowerCase() == 'true';
    return false;
  }

  int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  Future<List<_ExternalAdNetwork>> _loadNetworks() async {
    List<_ExternalAdNetwork> cachedNetworks = [];
    try {
      final localDb = await AdminLocalDbService.instance;
      final cachedData = await localDb.loadExternalAdNetworks();
      cachedNetworks = cachedData
          .map((n) => _ExternalAdNetwork.fromMap(n))
          .toList();
    } catch (_) {}

    try {
      final supabase = Supabase.instance.client;
      final networks = await supabase
          .from('ad_networks')
          .select()
          .order('priority', ascending: true)
          .timeout(const Duration(seconds: 10));

      final result = networks
          .map((n) => _ExternalAdNetwork.fromMap(n))
          .toList();

      try {
        final localDb = await AdminLocalDbService.instance;
        await localDb.saveExternalAdNetworks(
          networks.cast<Map<String, dynamic>>(),
        );
      } catch (_) {}

      return result;
    } catch (e) {
      return cachedNetworks;
    }
  }

  Future<_ExternalAdsDashboardData> _loadDashboardData() async {
    // Check if we have cached analytics that cover the requested range
    final requestedWindow = _analyticsWindowUtc();
    final cachedEntry = _findCachedAnalyticsCovering(
      requestedWindow.startUtc,
      requestedWindow.endUtc,
    );

    if (cachedEntry != null) {
      debugPrint(
        '[ExternalAds] Using cached analytics data for range: ${cachedEntry.data.totalImpressions} impressions, ${cachedEntry.data.totalClicks} clicks',
      );
      // Return cached data immediately - it already covers this range
      return cachedEntry.data;
    }

    debugPrint('[ExternalAds] Fetching fresh analytics data for range');

    // Try cached analytics data first (serves both offline mode and fast
    // initial render when the server call takes a moment).
    _ExternalAdsDashboardData? fromCache() {
      try {
        final raw = AdminLocalDbService.shared.loadExternalAdAnalyticsSync();
        if (raw.isEmpty) return null;
        final events =
            (raw['events'] as List<dynamic>?)
                ?.map(
                  (e) => _ExternalAdEventRow(
                    eventType: (e['event_type'] ?? '').toString(),
                    placement: (e['placement'] ?? '').toString(),
                    userId: (e['user_id'] ?? '').toString(),
                    createdAt: e['created_at'] != null
                        ? DateTime.tryParse(e['created_at'].toString())
                        : null,
                    clickCount: (e['click_count'] as int?) ?? 0,
                  ),
                )
                .toList(growable: false) ??
            [];
        return _ExternalAdsDashboardData(
          totalImpressions: (raw['total_impressions'] as num?)?.toInt() ?? 0,
          totalClicks: (raw['total_clicks'] as num?)?.toInt() ?? 0,
          ctrPercent: (raw['ctr_percent'] as num?)?.toDouble() ?? 0.0,
          campaignCount: (raw['campaign_count'] as num?)?.toInt() ?? 0,
          eventCount: (raw['event_count'] as num?)?.toInt() ?? 0,
          events: events,
          lastImpressionAt: DateTime.tryParse(
            (raw['last_impression_at'] ?? '').toString(),
          ),
          lastClickAt: DateTime.tryParse(
            (raw['last_click_at'] ?? '').toString(),
          ),
        );
      } catch (_) {
        return null;
      }
    }

    if (adminOfflineCacheManager.shouldUseCachedData()) {
      final cached = fromCache();
      if (cached != null) return cached;
      // No cached data available while offline — return empty dashboard
      // instead of throwing a network error.
      return const _ExternalAdsDashboardData.empty();
    }

    try {
      final supabase = Supabase.instance.client;
      final window = requestedWindow;
      final startDate = window.startUtc;
      final endDate = window.endUtc;

      final platformAnalytics = await supabase
          .rpc(
            'admin_list_external_ad_analytics_by_platform',
            params: {
              'p_start_date': startDate.toIso8601String(),
              'p_end_date': endDate.toIso8601String(),
            },
          )
          .timeout(const Duration(seconds: 10));

      final platformRows = ((platformAnalytics as List<dynamic>?) ?? [])
          .cast<Map<String, dynamic>>();

      final totalImpressions = platformRows.fold<int>(
        0,
        (sum, row) => sum + ((row['impressions'] as num?)?.toInt() ?? 0),
      );
      final totalClicks = platformRows.fold<int>(
        0,
        (sum, row) => sum + ((row['clicks'] as num?)?.toInt() ?? 0),
      );

      // Query last-event timestamps directly from ad_revenue_events.
      // For impressions: most recent created_at where event_type = 'impression'.
      DateTime? lastImpressionAt;
      try {
        final impressionResp = await supabase
            .from('ad_revenue_events')
            .select('created_at')
            .eq('event_type', 'impression')
            .gte('created_at', startDate.toIso8601String())
            .lte('created_at', endDate.toIso8601String())
            .order('created_at', ascending: false)
            .limit(1)
            .timeout(const Duration(seconds: 5));
        final impressionList = impressionResp as List<dynamic>;
        if (impressionList.isNotEmpty) {
          lastImpressionAt = DateTime.tryParse(
            (impressionList.first['created_at'] ?? '').toString(),
          );
        }
      } catch (_) {}

      // For clicks: most recent created_at where either event_type = 'click'
      //   or event_type = 'impression' with click_count > 0.
      DateTime? lastClickAt;
      try {
        final clickEventResp = await supabase
            .from('ad_revenue_events')
            .select('created_at')
            .eq('event_type', 'click')
            .gte('created_at', startDate.toIso8601String())
            .lte('created_at', endDate.toIso8601String())
            .order('created_at', ascending: false)
            .limit(1)
            .timeout(const Duration(seconds: 5));
        final clickEventList = clickEventResp as List<dynamic>;
        if (clickEventList.isNotEmpty) {
          lastClickAt = DateTime.tryParse(
            (clickEventList.first['created_at'] ?? '').toString(),
          );
        }
      } catch (_) {}

      try {
        final impClickResp = await supabase
            .from('ad_revenue_events')
            .select('created_at')
            .eq('event_type', 'impression')
            .gt('click_count', 0)
            .gte('created_at', startDate.toIso8601String())
            .lte('created_at', endDate.toIso8601String())
            .order('created_at', ascending: false)
            .limit(1)
            .timeout(const Duration(seconds: 5));
        final impClickList = impClickResp as List<dynamic>;
        if (impClickList.isNotEmpty) {
          final ts = DateTime.tryParse(
            (impClickList.first['created_at'] ?? '').toString(),
          );
          if (ts != null && (lastClickAt == null || ts.isAfter(lastClickAt))) {
            lastClickAt = ts;
          }
        }
      } catch (_) {}

      // Get recent events
      final eventsResult = await supabase
          .from('ad_revenue_events')
          .select()
          .gte('created_at', startDate.toIso8601String())
          .lte('created_at', endDate.toIso8601String())
          .order('created_at', ascending: false)
          .limit(10);

      final events = eventsResult
          .map(
            (e) => _ExternalAdEventRow(
              eventType: e['event_type'] ?? 'unknown',
              placement: e['placement'] ?? 'unknown',
              userId: e['user_id'] ?? 'unknown',
              createdAt: e['created_at'] != null
                  ? DateTime.parse(e['created_at'])
                  : null,
              clickCount: (e['click_count'] as int?) ?? 0,
            ),
          )
          .toList();

      final double ctr = totalImpressions > 0
          ? (totalClicks / totalImpressions) * 100
          : 0.0;

      // Get active networks count
      final networksResult = await supabase
          .from('ad_networks')
          .select()
          .eq('is_enabled', true)
          .count(CountOption.exact);
      final campaignCount = networksResult.count;

      final dashboardData = _ExternalAdsDashboardData(
        totalImpressions: totalImpressions,
        totalClicks: totalClicks,
        ctrPercent: ctr,
        campaignCount: campaignCount,
        eventCount: events.length,
        events: events,
        lastImpressionAt: lastImpressionAt,
        lastClickAt: lastClickAt,
      );

      debugPrint(
        '[ExternalAds] Fetched data: $totalImpressions impressions, $totalClicks clicks, CTR: ${ctr.toStringAsFixed(2)}%',
      );

      // Pre-load all drill-down data in background
      _preloadAllDrilldownData();

      // Save to local storage for offline access
      try {
        final localDb = await AdminLocalDbService.instance;
        final analyticsData = {
          'total_impressions': totalImpressions,
          'total_clicks': totalClicks,
          'ctr_percent': ctr,
          'campaign_count': campaignCount,
          'event_count': events.length,
          'last_impression_at': lastImpressionAt?.toIso8601String(),
          'last_click_at': lastClickAt?.toIso8601String(),
          'events': events
              .map(
                (e) => {
                  'event_type': e.eventType,
                  'placement': e.placement,
                  'user_id': e.userId,
                  'created_at': e.createdAt?.toIso8601String(),
                  'click_count': e.clickCount,
                },
              )
              .toList(),
        };
        await localDb.saveExternalAdAnalytics(analyticsData);
      } catch (_) {}

      // Cache this data with its date range
      _cacheAnalyticsData(dashboardData, startDate, endDate);

      return dashboardData;
    } catch (e, stackTrace) {
      debugPrint('[ExternalAds] _loadDashboardData ERROR: $e');
      debugPrint('[ExternalAds] Stack trace: $stackTrace');
      // Return empty dashboard on error instead of crashing
      // DO NOT cache empty/error data
      return const _ExternalAdsDashboardData.empty();
    }
  }

  /// Pre-load all drill-down data types in the background (cache only, no UI update)
  Future<void> _preloadAllDrilldownData() async {
    // Skip pre-load when offline — the Supabase calls would fail and the
    // data isn't needed until the user navigates to a drill-down view.
    if (adminOfflineCacheManager.shouldUseCachedData()) return;

    final types = ['network', 'placement', 'platform'];
    for (final type in types) {
      try {
        final localDb = await AdminLocalDbService.instance;
        final supabase = Supabase.instance.client;
        final window = _analyticsWindowUtc();
        final startDate = window.startUtc;
        final endDate = window.endUtc;

        List<Map<String, dynamic>> result = [];

        switch (type) {
          case 'network':
            final data = await supabase
                .rpc(
                  'admin_list_external_ad_analytics_by_network',
                  params: {
                    'p_start_date': startDate.toIso8601String(),
                    'p_end_date': endDate.toIso8601String(),
                  },
                )
                .timeout(const Duration(seconds: 10));
            result = (data as List<dynamic>).cast<Map<String, dynamic>>();
            break;
          case 'placement':
            final data = await supabase
                .rpc(
                  'admin_list_external_ad_analytics_by_placement',
                  params: {
                    'p_start_date': startDate.toIso8601String(),
                    'p_end_date': endDate.toIso8601String(),
                  },
                )
                .timeout(const Duration(seconds: 10));
            result = (data as List<dynamic>).cast<Map<String, dynamic>>();
            break;
          case 'platform':
            final data = await supabase
                .rpc(
                  'admin_list_external_ad_analytics_by_platform',
                  params: {
                    'p_start_date': startDate.toIso8601String(),
                    'p_end_date': endDate.toIso8601String(),
                  },
                )
                .timeout(const Duration(seconds: 10));
            result = (data as List<dynamic>).cast<Map<String, dynamic>>();
            break;
        }

        await localDb.saveExternalAdDrilldown('$type:$_rangeCacheKey', result);
      } catch (_) {}
    }
  }

  Future<void> _loadDrilldownData(String type, {bool silent = false}) async {
    if (!silent) {
      setState(() {
        _selectedDrilldown = type;
        _isLoadingDrilldown = true;
        _drilldownData = null;
      });
    }

    try {
      final localDb = await AdminLocalDbService.instance;

      // Silent preload: if we already have data from cache, skip to avoid "jump"
      if (silent && _drilldownData != null) return;

      // Silent preload: serve cached data immediately if available
      if (silent) {
        final cachedData = localDb.loadExternalAdDrilldownSync(
          '$type:$_rangeCacheKey',
        );
        if (cachedData.isNotEmpty && mounted) {
          setState(() {
            _drilldownData = cachedData;
            _selectedDrilldown = type;
            _isLoadingDrilldown = false;
          });
          return;
        }
      }

      // If offline, serve cached data (or empty) without hitting the server.
      if (adminOfflineCacheManager.shouldUseCachedData()) {
        final cachedData = localDb.loadExternalAdDrilldownSync(
          '$type:$_rangeCacheKey',
        );
        if (mounted) {
          setState(() {
            _drilldownData = cachedData.isNotEmpty ? cachedData : const [];
            _selectedDrilldown = type;
            _isLoadingDrilldown = false;
          });
        }
        return;
      }

      // Fetch fresh from server
      final supabase = Supabase.instance.client;
      final window = _analyticsWindowUtc();
      final startDate = window.startUtc;
      final endDate = window.endUtc;

      List<Map<String, dynamic>> result = [];

      switch (type) {
        case 'network':
          final data = await supabase
              .rpc(
                'admin_list_external_ad_analytics_by_network',
                params: {
                  'p_start_date': startDate.toIso8601String(),
                  'p_end_date': endDate.toIso8601String(),
                },
              )
              .timeout(const Duration(seconds: 10));
          result = (data as List<dynamic>).cast<Map<String, dynamic>>();
          break;
        case 'placement':
          final data = await supabase
              .rpc(
                'admin_list_external_ad_analytics_by_placement',
                params: {
                  'p_start_date': startDate.toIso8601String(),
                  'p_end_date': endDate.toIso8601String(),
                },
              )
              .timeout(const Duration(seconds: 10));
          result = (data as List<dynamic>).cast<Map<String, dynamic>>();
          break;
        case 'platform':
          final data = await supabase
              .rpc(
                'admin_list_external_ad_analytics_by_platform',
                params: {
                  'p_start_date': startDate.toIso8601String(),
                  'p_end_date': endDate.toIso8601String(),
                },
              )
              .timeout(const Duration(seconds: 10));
          result = (data as List<dynamic>).cast<Map<String, dynamic>>();
          break;
      }

      // Save to cache
      await localDb.saveExternalAdDrilldown('$type:$_rangeCacheKey', result);

      // Update UI: silent mode only updates if nothing was already displayed
      if (mounted && (!silent || _drilldownData == null)) {
        setState(() {
          _drilldownData = result;
          _selectedDrilldown = type;
          _isLoadingDrilldown = false;
        });
      }
    } catch (_) {
      if (mounted && !silent) {
        setState(() {
          _isLoadingDrilldown = false;
        });
      }
    }
  }
}

// ==================== DATA CLASSES ====================
class _ExternalAdConfigState {
  const _ExternalAdConfigState({
    required this.isEnabled,
    required this.displayOrder,
    required this.placementsEnabled,
    required this.tiersEnabled,
    required this.platformsEnabled,
    required this.rateLimitConfigs,
  });

  final bool isEnabled;
  final String displayOrder;
  final Map<String, bool> placementsEnabled;
  final Map<String, bool> tiersEnabled;
  final Map<String, bool> platformsEnabled;
  final Map<String, int?> rateLimitConfigs;
}

class _ExternalAdConfigOriginals {
  bool isEnabled = false;
  String displayOrder = 'external_first';
  Map<String, bool> placementsEnabled = {};
  Map<String, bool> tiersEnabled = {};
  Map<String, bool> platformsEnabled = {};
  Map<String, int?> rateLimitConfigs = {};
}

class _ExternalAdNetwork {
  const _ExternalAdNetwork({
    required this.id,
    required this.provider,
    required this.displayName,
    required this.isEnabled,
    required this.priority,
  });

  final String id;
  final String provider;
  final String displayName;
  final bool isEnabled;
  final int priority;

  factory _ExternalAdNetwork.fromMap(Map<String, dynamic> data) {
    return _ExternalAdNetwork(
      id: (data['id'] ?? '').toString(),
      provider: (data['provider'] ?? '').toString(),
      displayName: (data['display_name'] ?? '').toString(),
      isEnabled: data['is_enabled'] ?? false,
      priority: (data['priority'] ?? 100) as int,
    );
  }
}

class _ExternalAdEventRow {
  const _ExternalAdEventRow({
    required this.eventType,
    required this.placement,
    required this.userId,
    this.createdAt,
    required this.clickCount,
  });

  final String eventType;
  final String placement;
  final String userId;
  final DateTime? createdAt;
  final int clickCount;
}

class _ExternalAdsDashboardData {
  const _ExternalAdsDashboardData({
    required this.totalImpressions,
    required this.totalClicks,
    required this.ctrPercent,
    required this.campaignCount,
    required this.eventCount,
    required this.events,
    this.lastImpressionAt,
    this.lastClickAt,
  });

  const _ExternalAdsDashboardData.empty()
    : totalImpressions = 0,
      totalClicks = 0,
      ctrPercent = 0.0,
      campaignCount = 0,
      eventCount = 0,
      events = const <_ExternalAdEventRow>[],
      lastImpressionAt = null,
      lastClickAt = null;

  final int totalImpressions;
  final int totalClicks;
  final double ctrPercent;
  final int campaignCount;
  final int eventCount;
  final List<_ExternalAdEventRow> events;
  final DateTime? lastImpressionAt;
  final DateTime? lastClickAt;
}
