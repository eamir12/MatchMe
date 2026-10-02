import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:matchme_admin/services/admin_local_db_service.dart';
import 'package:matchme_admin/services/admin_offline_cache_manager.dart';
import 'package:matchme_admin/services/public_reference_data_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef AdminTextLookup =
    String Function(String key, {Map<String, String>? params});

enum _SponsoredCampaignFilter {
  all,
  approved,
  draft,
  paused,
  rejected,
  disabled,
}

class AdminSponsoredAdsDashboard extends StatefulWidget {
  const AdminSponsoredAdsDashboard({
    super.key,
    required this.t,
    required this.localeCode,
    required this.textDirection,
  });

  final AdminTextLookup t;
  final String localeCode;
  final TextDirection textDirection;

  @override
  State<AdminSponsoredAdsDashboard> createState() =>
      _AdminSponsoredAdsDashboardState();
}

class _AdminSponsoredAdsDashboardState extends State<AdminSponsoredAdsDashboard>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  static const _imageBucket = 'sponsored-ad-images';
  static const _tabCount = 4;
  static const List<String> _platformOptions = <String>[
    'android',
    'ios',
    'web',
    'windows',
    'macos',
    'linux',
  ];

  final _searchController = TextEditingController();
  final _internalNameController = TextEditingController();
  final _advertiserNameController = TextEditingController();
  final _destinationUrlController = TextEditingController();
  final _imageUrlController = TextEditingController();
  final _sortPriorityController = TextEditingController(text: '100');
  final _dailyImpressionCapController = TextEditingController();
  final _totalImpressionCapController = TextEditingController();
  final _maxImpressionsController = TextEditingController(text: '3');
  final _minMinutesController = TextEditingController(text: '8');
  final _firstDelaySecondsController = TextEditingController(text: '90');

  final _headlineEnController = TextEditingController();
  final _headlineEsController = TextEditingController();
  final _headlineHeController = TextEditingController();
  final _bodyEnController = TextEditingController();
  final _bodyEsController = TextEditingController();
  final _bodyHeController = TextEditingController();
  final _ctaEnController = TextEditingController();
  final _ctaEsController = TextEditingController();
  final _ctaHeController = TextEditingController();
  final _sponsorEnController = TextEditingController();
  final _sponsorEsController = TextEditingController();
  final _sponsorHeController = TextEditingController();

  _SponsoredCampaignFilter _filter = _SponsoredCampaignFilter.all;
  String _moderationStatus = 'draft';
  final Set<String> _selectedPlacements = {'home_inline'};
  final Set<String> _selectedPlatforms = {
    'android',
    'ios',
    'web',
    'windows',
    'macos',
    'linux',
  };
  final Set<String> _selectedTiers = {'free'};
  bool _familySafe = true;
  bool _campaignActive = true;
  bool _creativeActive = true;
  DateTime? _startsAt;
  DateTime? _endsAt;
  bool _isSaving = false;
  bool _isSavingConfig = false;
  bool _isUploadingImage = false;
  bool _configHydrated = false;
  bool _serverConfigHydrated = false;
  bool _isHydratingConfig = false;
  bool _hasLocalConfigEdits = false;

  /// True when the displayed config was read from the server (complete or
  /// partial). False only when the read failed or we fell back to the local
  /// snapshot, in which case the visible values may be client-side defaults
  /// and Configuration disables Save so they cannot overwrite real settings.
  bool _configVerified = false;
  bool _adsEnabled = false;
  bool _sponsoredCardsEnabled = true;
  bool _familySafeOnly = true;
  bool _reportEnabled = true;

  // Original values for change detection (set when config loads)
  bool _originalAdsEnabled = false;
  bool _originalSponsoredCardsEnabled = true;
  bool _originalFamilySafeOnly = true;
  bool _originalReportEnabled = true;
  int _originalMaxImpressions = 3;
  int _originalMinMinutes = 8;
  int _originalFirstDelaySeconds = 90;
  final Set<String> _originalAllowedPlacements = {};
  final Set<String> _originalAllowedPlatforms = {};
  final Set<String> _originalAllowedTiers = {};

  // Master controls for internal ad system
  final Set<String> _masterAllowedPlacements = {
    'home_inline',
    'matches_inline',
    'chats_inline',
    'events_inline',
    'profile_inline',
  };
  final Set<String> _masterAllowedPlatforms = {
    'android',
    'ios',
    'web',
    'windows',
    'macos',
    'linux',
  };
  final Set<String> _masterAllowedTiers = {'free', 'plus', 'gold', 'platinum'};
  // NOTE: `ads.display_order` is intentionally NOT owned by this screen. It is
  // a global setting shared by both ad systems and is edited (and written) by
  // the External tab only, so a second control here would silently clobber it.

  String? _editingCampaignId;
  String? _headlineKey;
  String? _bodyKey;
  String? _ctaKey;
  String? _sponsorNameKey;
  TabController? _tabController;
  Future<_SponsoredAdConfigState>? _adConfigFuture;
  Future<_SponsoredDashboardData>? _dashboardFuture;
  Future<List<_SponsoredLocaleOption>>? _localeOptionsFuture;
  bool _isLoadingEditor = false;
  bool _isSubscribed = false;
  StreamSubscription<bool>? _availabilitySub;
  Timer? _dashboardReloadDebounce;

  // Analytics date-range state
  // Preset codes: '7d' | '30d' | '90d' | 'all' | 'custom'
  String _rangePreset = '30d';
  DateTime? _customStart; // local time
  DateTime? _customEnd; // local time

  // Cached data state (loaded once, stored in memory)
  _SponsoredAdConfigState? _cachedConfig;
  _SponsoredDashboardData? _cachedDashboard;

  // Smart analytics cache: stores fetched data with their date ranges
  // Key: cache identifier (preset or custom range string)
  // Value: (data, startUtc, endUtc)
  final Map<
    String,
    ({_SponsoredDashboardData data, DateTime startUtc, DateTime endUtc})
  >
  _analyticsCache = {};
  Timer? _analyticsPersistDebounce;
  _SponsoredCampaignRow? _editingCampaignPreview;
  _SponsoredEditorDraft _editorBaseline = const _SponsoredEditorDraft.empty();
  int _lastSettledTabIndex = 0;
  bool _isHandlingTabTransition = false;
  List<_SponsoredLocaleOption> _availableLocaleOptions = const [];
  final Set<String> _selectedLocaleCodes = {'en', 'es', 'he'};
  final Set<String> _expandedLocaleCodes = {'en'};
  final Map<String, _SponsoredLocaleInputs> _extraLocaleInputs = {};
  Set<String> _persistedLocaleCodes = <String>{};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _ensureTabController();
    _maxImpressionsController.addListener(_handleConfigTextFieldChanged);
    _minMinutesController.addListener(_handleConfigTextFieldChanged);
    _firstDelaySecondsController.addListener(_handleConfigTextFieldChanged);
    _initializeAndLoadFromLocalStorage().then((_) {
      _primeFutures();
    });
    _clearFormFields();
    _setupRealtimeSubscription();

    // Re-establish realtime subscriptions when connectivity is restored
    _availabilitySub = adminOfflineCacheManager.availabilityStream.listen((
      available,
    ) {
      if (!mounted) return;
      if (available) {
        _isSubscribed = false;
        _setupRealtimeSubscription();
      }
    });
  }

  /// Initialize local DB service and load data synchronously for immediate UI rendering
  Future<void> _initializeAndLoadFromLocalStorage() async {
    try {
      // Ensure local DB is initialized
      final localDb = await AdminLocalDbService.instance;

      // Load config synchronously after initialization
      final cachedConfig = localDb.loadAppConfigSync();
      if (cachedConfig != null && cachedConfig.isNotEmpty && mounted) {
        final config = _buildConfigStateFromMap(cachedConfig);
        setState(() {
          _cachedConfig = config;
          _hydrateConfig(config);
        });
      }

      // Load campaigns and metrics synchronously (like external ads dashboard)
      final cachedAds = localDb.loadSponsoredAdsSync();
      final cachedAnalytics = localDb.loadSponsoredAdAnalyticsSync();

      // Load persisted analytics cache (all date ranges)
      final persistedCache = localDb.loadSponsoredAdAnalyticsCacheSync();
      if (persistedCache.isNotEmpty && mounted) {
        _restoreAnalyticsCacheFromPersisted(persistedCache);
        debugPrint(
          '[SponsoredAds] Restored ${_analyticsCache.length} cached date ranges from storage',
        );
      }

      if (cachedAds.isNotEmpty && mounted) {
        final campaigns = _parseCampaignRows(cachedAds);
        // Parse cached metrics if available
        final metrics = _parseMetricsFromCache(cachedAnalytics);
        final reportSummaries = _parseReportSummariesFromCache(cachedAnalytics);
        setState(() {
          _cachedDashboard = _SponsoredDashboardData(
            campaigns: campaigns,
            metricsByCampaign: metrics,
            recentReports: const [],
            reportSummariesByCampaign: reportSummaries,
          );
        });
      }
    } catch (_) {}
  }

  /// Parse metrics from cached analytics data
  Map<String, _SponsoredCampaignMetrics> _parseMetricsFromCache(
    Map<String, dynamic>? analytics,
  ) {
    if (analytics == null) return {};
    final metricsList = analytics['metrics'] as List<dynamic>?;
    if (metricsList == null) return {};
    final map = <String, _SponsoredCampaignMetrics>{};
    for (final item in metricsList) {
      if (item is Map<String, dynamic>) {
        final metric = _SponsoredCampaignMetrics.fromMap(item);
        map[metric.campaignId] = metric;
      }
    }
    return map;
  }

  /// Parse report summaries from cached analytics data
  Map<String, _SponsoredCampaignReportSummary> _parseReportSummariesFromCache(
    Map<String, dynamic>? analytics,
  ) {
    if (analytics == null) return {};
    final summariesList = analytics['reportSummaries'] as List<dynamic>?;
    if (summariesList == null) return {};
    final map = <String, _SponsoredCampaignReportSummary>{};
    for (final item in summariesList) {
      if (item is Map<String, dynamic>) {
        final summary = _SponsoredCampaignReportSummary.fromMap(item);
        map[summary.campaignId] = summary;
      }
    }
    return map;
  }

  void _ensureTabController({int? preferredIndex}) {
    final current = _tabController;
    if (current != null && current.length == _tabCount) {
      return;
    }

    final previousIndex =
        preferredIndex ?? current?.index ?? _lastSettledTabIndex;
    current?.removeListener(_handleTabControllerChanged);
    current?.dispose();
    _tabController = TabController(
      length: _tabCount,
      vsync: this,
      initialIndex: previousIndex.clamp(0, _tabCount - 1),
    );
    _tabController!.addListener(_handleTabControllerChanged);
    _lastSettledTabIndex = _tabController!.index;
  }

  TabController get _safeTabController {
    _ensureTabController();
    return _tabController!;
  }

  void _primeFutures() {
    _adConfigFuture ??= _loadAdConfig().then((data) {
      if (mounted) setState(() => _cachedConfig = data);
      return data;
    });
    _dashboardFuture ??= _loadDashboardData().then((data) {
      if (mounted) setState(() => _cachedDashboard = data);
      return data;
    });
    _localeOptionsFuture ??= _loadLocaleOptions();
  }

  bool get _hasUnsavedEditorChanges => _captureEditorDraft() != _editorBaseline;

  bool get _hasActiveEditorSession =>
      _editingCampaignId != null ||
      _editingCampaignPreview != null ||
      _hasEditorContent;

  bool get _hasEditorContent {
    if (_selectedLocaleCodes.length != 3 ||
        !_selectedLocaleCodes.containsAll(const {'en', 'es', 'he'})) {
      return true;
    }

    if (_internalNameController.text.trim().isNotEmpty ||
        _advertiserNameController.text.trim().isNotEmpty ||
        _destinationUrlController.text.trim().isNotEmpty ||
        _imageUrlController.text.trim().isNotEmpty ||
        _sortPriorityController.text.trim() != '100' ||
        _dailyImpressionCapController.text.trim().isNotEmpty ||
        _totalImpressionCapController.text.trim().isNotEmpty ||
        _moderationStatus != 'draft' ||
        !_selectedPlacements.contains('home_inline') ||
        !_listEquals(
          _orderedSelectedPlatforms(),
          _platformOptions
              .where(_masterAllowedPlatforms.contains)
              .toList(growable: false),
        ) ||
        !_familySafe ||
        !_campaignActive ||
        !_creativeActive ||
        _startsAt != null ||
        _endsAt != null) {
      return true;
    }

    return _orderedSelectedLocaleCodes().any((code) => !_isLocaleEmpty(code));
  }

  _SponsoredEditorDraft _captureEditorDraft() {
    return _SponsoredEditorDraft(
      internalName: _internalNameController.text.trim(),
      advertiserName: _advertiserNameController.text.trim(),
      destinationUrl: _destinationUrlController.text.trim(),
      imageUrl: _imageUrlController.text.trim(),
      sortPriority: _sortPriorityController.text.trim(),
      dailyCap: _dailyImpressionCapController.text.trim(),
      totalCap: _totalImpressionCapController.text.trim(),
      moderationStatus: _moderationStatus,
      placements: _selectedPlacements.toList(),
      platformSignature: _buildPlatformSignature(),
      familySafe: _familySafe,
      campaignActive: _campaignActive,
      creativeActive: _creativeActive,
      startsAtIso: _startsAt?.toIso8601String() ?? '',
      endsAtIso: _endsAt?.toIso8601String() ?? '',
      headlineEn: _headlineEnController.text.trim(),
      headlineEs: _headlineEsController.text.trim(),
      headlineHe: _headlineHeController.text.trim(),
      bodyEn: _bodyEnController.text.trim(),
      bodyEs: _bodyEsController.text.trim(),
      bodyHe: _bodyHeController.text.trim(),
      ctaEn: _ctaEnController.text.trim(),
      ctaEs: _ctaEsController.text.trim(),
      ctaHe: _ctaHeController.text.trim(),
      sponsorEn: _sponsorEnController.text.trim(),
      sponsorEs: _sponsorEsController.text.trim(),
      sponsorHe: _sponsorHeController.text.trim(),
      localeSignature: _buildLocaleSignature(),
      targetTiers: _selectedTiers.toList(),
    );
  }

  String _buildLocaleSignature() {
    final codes = _orderedSelectedLocaleCodes();
    return codes
        .map((code) {
          // Peek, don't allocate: this runs from _captureEditorDraft(), which is
          // reached through the _hasUnsavedEditorChanges getter during build.
          final inputs = _peekLocaleInputsFor(code);
          return [
            code,
            inputs.headline.text.trim(),
            inputs.body.text.trim(),
            inputs.cta.text.trim(),
            inputs.sponsor.text.trim(),
          ].join('|');
        })
        .join('||');
  }

  String _buildPlatformSignature() {
    return _orderedSelectedPlatforms().join('|');
  }

  List<String> _orderedSelectedPlatforms() {
    return _platformOptions
        .where(_selectedPlatforms.contains)
        .toList(growable: false);
  }

  bool _isEditorAtPristineShell() {
    return _editingCampaignId == null &&
        _editingCampaignPreview == null &&
        _internalNameController.text.trim().isEmpty &&
        _advertiserNameController.text.trim().isEmpty &&
        _destinationUrlController.text.trim().isEmpty &&
        _imageUrlController.text.trim().isEmpty &&
        _sortPriorityController.text.trim() == '100' &&
        _dailyImpressionCapController.text.trim().isEmpty &&
        _totalImpressionCapController.text.trim().isEmpty &&
        _moderationStatus == 'draft' &&
        _listEquals(_selectedPlacements.toList(), const ['home_inline']) &&
        _selectedLocaleCodes.length == 3 &&
        _selectedLocaleCodes.containsAll(const {'en', 'es', 'he'}) &&
        _familySafe &&
        _campaignActive &&
        _creativeActive &&
        _startsAt == null &&
        _endsAt == null &&
        _headlineEnController.text.trim().isEmpty &&
        _headlineEsController.text.trim().isEmpty &&
        _headlineHeController.text.trim().isEmpty &&
        _bodyEnController.text.trim().isEmpty &&
        _bodyEsController.text.trim().isEmpty &&
        _bodyHeController.text.trim().isEmpty &&
        _ctaEnController.text.trim().isEmpty &&
        _ctaEsController.text.trim().isEmpty &&
        _ctaHeController.text.trim().isEmpty &&
        _sponsorEnController.text.trim().isEmpty &&
        _sponsorEsController.text.trim().isEmpty &&
        _sponsorHeController.text.trim().isEmpty;
  }

  List<String> _orderedDistinctPlatforms(Iterable<String> values) {
    final available = values.toSet();
    return _platformOptions.where(available.contains).toList(growable: false);
  }

  List<String> _orderedDistinctPlacements(Iterable<String> values) {
    return _orderedPlacements(values.toSet());
  }

  /// Deterministic placement order for both display and persisted config.
  List<String> _orderedPlacements(Set<String> values) {
    const placementOrder = <String>[
      'home_inline',
      'matches_inline',
      'chats_inline',
      'events_inline',
      'profile_inline',
    ];
    final known = placementOrder.where(values.contains).toList(growable: false);
    // Preserve any unexpected value rather than dropping it silently.
    final extra = values.where((v) => !placementOrder.contains(v)).toList()
      ..sort();
    return <String>[...known, ...extra];
  }

  /// Deterministic platform order for both display and persisted config.
  List<String> _orderedPlatforms(Set<String> values) {
    final known = _platformOptions
        .where(values.contains)
        .toList(growable: false);
    final extra = values.where((v) => !_platformOptions.contains(v)).toList()
      ..sort();
    return <String>[...known, ...extra];
  }

  /// Deterministic subscription-tier order for persisted config.
  List<String> _orderedTiers(Set<String> values) {
    const tierOrder = <String>['free', 'plus', 'gold', 'platinum'];
    final known = tierOrder.where(values.contains).toList(growable: false);
    final extra = values.where((v) => !tierOrder.contains(v)).toList()..sort();
    return <String>[...known, ...extra];
  }

  void _markEditorClean() {
    _editorBaseline = _captureEditorDraft();
  }

  void _handleTabControllerChanged() {
    final controller = _tabController;
    if (controller == null || _isHandlingTabTransition) {
      return;
    }

    final targetIndex = controller.index;
    if (targetIndex == _lastSettledTabIndex) {
      return;
    }

    _handleTabTransition(targetIndex);
  }

  Future<void> _handleTabTransition(int targetIndex) async {
    final controller = _tabController;
    if (controller == null || _isHandlingTabTransition) {
      return;
    }

    _isHandlingTabTransition = true;
    final previousIndex = _lastSettledTabIndex;
    final isLeavingEditor = previousIndex == 3 && targetIndex != 3;

    var allowed = true;
    if (isLeavingEditor) {
      allowed = await _resolveEditorExit(
        targetTabIndex: targetIndex,
        closeEditorWhenClean: true,
      );
    }

    if (!mounted) {
      _isHandlingTabTransition = false;
      return;
    }

    if (allowed) {
      _lastSettledTabIndex = targetIndex;
    } else {
      controller.animateTo(previousIndex);
    }

    _isHandlingTabTransition = false;
  }

  Future<bool> _resolveEditorExit({
    int? targetTabIndex,
    required bool closeEditorWhenClean,
  }) async {
    if (!_hasActiveEditorSession) {
      return true;
    }

    if (!_hasUnsavedEditorChanges) {
      if (closeEditorWhenClean) {
        setState(() {
          _clearFormFields();
        });
      }
      return true;
    }

    final choice = await _showUnsavedChangesDialog();
    if (choice == null || !mounted) {
      return false;
    }

    switch (choice) {
      case _SponsoredEditorExitAction.save:
        return _saveCampaign(
          navigateToCampaigns: false,
          targetTabIndexAfterSave: targetTabIndex,
        );
      case _SponsoredEditorExitAction.discard:
        setState(() {
          _clearFormFields();
        });
        return true;
      case _SponsoredEditorExitAction.cancel:
        return false;
    }
  }

  Future<_SponsoredEditorExitAction?> _showUnsavedChangesDialog() async {
    final t = widget.t;
    return showDialog<_SponsoredEditorExitAction>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(t('adminSponsoredAdsUnsavedTitle')),
          content: Text(t('adminSponsoredAdsUnsavedBody')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_SponsoredEditorExitAction.cancel),
              child: Text(t('generalCancel')),
            ),
            OutlinedButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_SponsoredEditorExitAction.discard),
              child: Text(t('adminSponsoredAdsUnsavedDiscard')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_SponsoredEditorExitAction.save),
              child: Text(t('generalSave')),
            ),
          ],
        );
      },
    );
  }

  Future<_SponsoredAdConfigState> get _safeAdConfigFuture {
    return _adConfigFuture ??= _loadAdConfig();
  }

  Future<_SponsoredDashboardData> get _safeDashboardFuture {
    // Always return the current _dashboardFuture, creating one if needed
    _dashboardFuture ??= _loadDashboardData();
    return _dashboardFuture!;
  }

  Future<List<_SponsoredLocaleOption>> get _safeLocaleOptionsFuture {
    return _localeOptionsFuture ??= _loadLocaleOptions();
  }

  List<_SponsoredLocaleOption> get _defaultLocaleOptions => [
    _SponsoredLocaleOption(
      code: 'en',
      displayName: widget.t('adminIntentsInterestsLocaleEn'),
    ),
    _SponsoredLocaleOption(
      code: 'es',
      displayName: widget.t('adminIntentsInterestsLocaleEs'),
    ),
    _SponsoredLocaleOption(
      code: 'he',
      displayName: widget.t('adminIntentsInterestsLocaleHe'),
    ),
  ];

  @override
  void reassemble() {
    super.reassemble();
    // Don't clear futures - they should persist when app comes to foreground
    // Only clear config hydrated flag to allow config updates if needed
    _configHydrated = false;
  }

  @override
  void dispose() {
    _availabilitySub?.cancel();
    _dashboardReloadDebounce?.cancel();
    _analyticsPersistDebounce?.cancel();
    _tabController?.removeListener(_handleTabControllerChanged);
    _tabController?.dispose();
    _searchController.dispose();
    _internalNameController.dispose();
    _advertiserNameController.dispose();
    _destinationUrlController.dispose();
    _imageUrlController.dispose();
    _sortPriorityController.dispose();
    _dailyImpressionCapController.dispose();
    _totalImpressionCapController.dispose();
    _maxImpressionsController.dispose();
    _minMinutesController.dispose();
    _firstDelaySecondsController.dispose();
    _headlineEnController.dispose();
    _headlineEsController.dispose();
    _headlineHeController.dispose();
    _bodyEnController.dispose();
    _bodyEsController.dispose();
    _bodyHeController.dispose();
    _ctaEnController.dispose();
    _ctaEsController.dispose();
    _ctaHeController.dispose();
    _sponsorEnController.dispose();
    _sponsorEsController.dispose();
    _sponsorHeController.dispose();
    for (final inputs in _extraLocaleInputs.values) {
      inputs.dispose();
    }
    super.dispose();
  }

  void _handleConfigTextFieldChanged() {
    if (_isHydratingConfig || !mounted) {
      return;
    }
    if (_hasLocalConfigEdits) {
      setState(() {});
      return;
    }
    setState(() {
      _hasLocalConfigEdits = true;
    });
  }

  void _markConfigEdited() {
    _hasLocalConfigEdits = true;
  }

  void _setupRealtimeSubscription() {
    // Skip realtime subscriptions when offline to avoid noisy connection errors
    if (adminOfflineCacheManager.shouldUseCachedData()) {
      _isSubscribed = true;
      return;
    }
    if (_isSubscribed) return;
    _isSubscribed = true;
    try {
      // Helper to suppress noisy realtime error logs when the device is offline.
      // The Supabase client retries connections automatically, and each failed
      // attempt would otherwise flood the log with SocketExceptions.
      void logRealtimeError(String label, Object error) {
        if (!adminOfflineCacheManager.shouldUseCachedData()) {
          debugPrint('[SponsoredAds] $label realtime error: $error');
        }
      }

      // Listen to app_config changes (ad settings)
      Supabase.instance.client
          .from('app_config')
          .stream(primaryKey: ['config_key'])
          .listen((data) {
            debugPrint('[SponsoredAds] app_config realtime update received');
            if (!mounted) return;
            if (_hasLocalConfigEdits || _isSavingConfig) return;
            _refresh();
          }, onError: (error) => logRealtimeError('app_config', error));

      // Listen to ad_campaigns changes (campaign updates)
      Supabase.instance.client
          .from('ad_campaigns')
          .stream(primaryKey: ['id'])
          .listen((data) {
            debugPrint('[SponsoredAds] ad_campaigns realtime update received');
            // Campaign rows are authoritative server state, so the aggregates
            // cache must be dropped to guarantee a fresh read.
            if (mounted) _scheduleDashboardReload(clearCache: true);
          }, onError: (error) => logRealtimeError('ad_campaigns', error));

      // Listen to ad_creatives changes (creative updates)
      Supabase.instance.client
          .from('ad_creatives')
          .stream(primaryKey: ['id'])
          .listen((data) {
            debugPrint('[SponsoredAds] ad_creatives realtime update received');
            if (mounted) _scheduleDashboardReload(clearCache: true);
          }, onError: (error) => logRealtimeError('ad_creatives', error));

      // Listen to ad_impressions changes (impression tracking)
      Supabase.instance.client
          .from('ad_impressions')
          .stream(primaryKey: ['id'])
          .listen((data) {
            debugPrint(
              '[SponsoredAds] ad_impressions realtime update received: ${data.length} records',
            );
            // Clear local cache to ensure fresh data on mobile
            _clearLocalCache();
            // Apply local increment for immediate UI update (no full reload)
            if (mounted) {
              _applyImpressionIncrement(data.cast<Map<String, dynamic>>());
            }
          }, onError: (error) => logRealtimeError('ad_impressions', error));

      // Listen to ad_clicks changes (click tracking)
      Supabase.instance.client.from('ad_clicks').stream(primaryKey: ['id']).listen((
        data,
      ) {
        debugPrint(
          '[SponsoredAds] ad_clicks realtime update received: ${data.length} records',
        );
        // Clear local cache to ensure fresh data on mobile
        _clearLocalCache();
        // Apply local increment for immediate UI update (no full reload)
        if (mounted) _applyClickIncrement(data.cast<Map<String, dynamic>>());
      }, onError: (error) => logRealtimeError('ad_clicks', error));

      // Listen to ad_reports changes (report tracking)
      Supabase.instance.client
          .from('ad_reports')
          .stream(primaryKey: ['id'])
          .listen((data) {
            debugPrint('[SponsoredAds] ad_reports realtime update received');
            if (mounted) _scheduleDashboardReload(clearCache: true);
          }, onError: (error) => logRealtimeError('ad_reports', error));

      debugPrint('[SponsoredAds] Realtime subscriptions established');
    } catch (e, stackTrace) {
      debugPrint('[SponsoredAds] Failed to setup realtime subscriptions: $e');
      debugPrint('[SponsoredAds] StackTrace: $stackTrace');
    }
  }

  /// Compute the analytics date window (local → UTC) from the active range.
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

  /// Locale-aware short date+time for "Last event" subtitles.
  String _formatEventDateTime(DateTime dt) {
    final local = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final hour12 = local.hour > 12
        ? local.hour - 12
        : (local.hour == 0 ? 12 : local.hour);
    return '${local.year}/${two(local.month)}/${two(local.day)} '
        '${two(hour12)}:${two(local.minute)} '
        '${local.hour >= 12 ? 'PM' : 'AM'}';
  }

  void _scheduleDashboardReload({bool clearCache = false}) {
    _dashboardReloadDebounce?.cancel();
    _dashboardReloadDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      // Clear the analytics cache so the UI refreshes with fresh numbers.
      if (clearCache) {
        _invalidateDashboardCaches();
        debugPrint(
          '[SponsoredAds] Cleared dashboard cache for realtime update',
        );
      }
      // Directly assign the future without wrapping in .then()
      _dashboardFuture = _loadDashboardData().then((data) {
        if (mounted) {
          setState(() => _cachedDashboard = data);
        }
        return data;
      });
      setState(() {});
    });
  }

  /// Track last processed impression ID to avoid counting initial sync as new
  final Set<String> _processedImpressionIds = <String>{};
  bool _hasProcessedInitialImpressionSnapshot = false;

  /// Apply impression increment locally for immediate UI update (no full reload)
  void _applyImpressionIncrement(List<Map<String, dynamic>> records) {
    if (!_hasProcessedInitialImpressionSnapshot) {
      // First event from the realtime subscription is the initial snapshot of ALL
      // existing records. These are already counted in the dashboard data, so just
      // track their IDs to prevent double-counting, regardless of _cachedDashboard state.
      for (final record in records) {
        final id = (record['id'] ?? '').toString();
        if (id.isNotEmpty) _processedImpressionIds.add(id);
      }
      _hasProcessedInitialImpressionSnapshot = true;
      debugPrint(
        '[SponsoredAds] Initial snapshot: tracked ${records.length} existing impressions',
      );
      return;
    }

    final current = _cachedDashboard;
    if (current == null) return;

    final nextMetrics = Map<String, _SponsoredCampaignMetrics>.from(
      current.metricsByCampaign,
    );
    var totalIncremented = 0;

    for (final record in records) {
      final id = (record['id'] ?? '').toString();
      if (id.isEmpty) continue;

      if (_processedImpressionIds.contains(id)) continue;
      _processedImpressionIds.add(id);

      final campaignId = (record['campaign_id'] ?? '').toString();
      if (campaignId.isEmpty) continue;

      final existing = nextMetrics[campaignId];
      if (existing != null) {
        nextMetrics[campaignId] = _SponsoredCampaignMetrics(
          campaignId: existing.campaignId,
          impressions: existing.impressions + 1,
          clicks: existing.clicks,
          reports: existing.reports,
          ctrPercent: _calculateCtr(existing.impressions + 1, existing.clicks),
        );
        totalIncremented++;
      }
    }

    if (totalIncremented > 0 && mounted) {
      debugPrint(
        '[SponsoredAds] Applied $totalIncremented NEW impression increments locally',
      );
      setState(() {
        _cachedDashboard = _SponsoredDashboardData(
          campaigns: current.campaigns,
          metricsByCampaign: nextMetrics,
          recentReports: current.recentReports,
          reportSummariesByCampaign: current.reportSummariesByCampaign,
        );
      });
    }
  }

  /// Track last processed click ID to avoid counting initial sync as new
  final Set<String> _processedClickIds = <String>{};
  bool _hasProcessedInitialClickSnapshot = false;

  /// Apply click increment locally for immediate UI update (no full reload)
  void _applyClickIncrement(List<Map<String, dynamic>> records) {
    if (!_hasProcessedInitialClickSnapshot) {
      // First event from the realtime subscription is the initial snapshot of ALL
      // existing records. These are already counted in the dashboard data, so just
      // track their IDs to prevent double-counting, regardless of _cachedDashboard state.
      for (final record in records) {
        final id = (record['id'] ?? '').toString();
        if (id.isNotEmpty) _processedClickIds.add(id);
      }
      _hasProcessedInitialClickSnapshot = true;
      debugPrint(
        '[SponsoredAds] Initial snapshot: tracked ${records.length} existing clicks',
      );
      return;
    }

    final current = _cachedDashboard;
    if (current == null) return;

    final nextMetrics = Map<String, _SponsoredCampaignMetrics>.from(
      current.metricsByCampaign,
    );
    var totalIncremented = 0;

    for (final record in records) {
      final id = (record['id'] ?? '').toString();
      if (id.isEmpty) continue;

      if (_processedClickIds.contains(id)) continue;
      _processedClickIds.add(id);

      final campaignId = (record['campaign_id'] ?? '').toString();
      if (campaignId.isEmpty) continue;

      final existing = nextMetrics[campaignId];
      if (existing != null) {
        nextMetrics[campaignId] = _SponsoredCampaignMetrics(
          campaignId: existing.campaignId,
          impressions: existing.impressions,
          clicks: existing.clicks + 1,
          reports: existing.reports,
          ctrPercent: _calculateCtr(existing.impressions, existing.clicks + 1),
        );
        totalIncremented++;
      }
    }

    if (totalIncremented > 0 && mounted) {
      debugPrint(
        '[SponsoredAds] Applied $totalIncremented NEW click increments locally',
      );
      setState(() {
        _cachedDashboard = _SponsoredDashboardData(
          campaigns: current.campaigns,
          metricsByCampaign: nextMetrics,
          recentReports: current.recentReports,
          reportSummariesByCampaign: current.reportSummariesByCampaign,
        );
      });
    }
  }

  double _calculateCtr(int impressions, int clicks) {
    if (impressions <= 0) return 0.0;
    return (clicks / impressions) * 100;
  }

  Future<void> _clearLocalCache() async {
    // Drop the in-memory per-range aggregates too. Otherwise the next
    // _loadDashboardData() would find an entry for the current (day-aligned)
    // range and reuse the pre-event totals, leaving analytics stale for the
    // rest of the day. The clear is persisted on a debounce: this runs on
    // every impression/click event, and without persisting, a restart would
    // restore the stale ranges from Hive.
    _analyticsCache.clear();
    _scheduleAnalyticsCachePersist();
    try {
      final localDb = await AdminLocalDbService.instance;
      // Clear only the analytics/metrics cache so the next full refresh re-fetches fresh
      // impression/click data. Don't wipe all boxes — that would erase campaigns that
      // haven't been refreshed yet, causing a spinner on next startup if the app is killed.
      await localDb.saveSponsoredAdAnalytics({});
      debugPrint('[SponsoredAds] Cleared analytics cache for realtime update');
    } catch (e) {
      debugPrint('[SponsoredAds] Error clearing local cache: $e');
    }
  }

  /// Debounced write of the analytics cache. Realtime impression/click events
  /// fire per event, so persisting synchronously would hammer Hive.
  void _scheduleAnalyticsCachePersist() {
    _analyticsPersistDebounce?.cancel();
    _analyticsPersistDebounce = Timer(
      const Duration(seconds: 2),
      _persistAnalyticsCache,
    );
  }

  Future<void> _persistCachedDashboard(_SponsoredDashboardData data) async {
    try {
      final localDb = await AdminLocalDbService.instance;
      await localDb.saveSponsoredAds(
        data.campaigns
            .map((campaign) => campaign.toMap())
            .toList(growable: false),
      );
      await localDb.saveSponsoredAdAnalytics({
        'metrics': data.metricsByCampaign.values
            .map((metric) => metric.toMap())
            .toList(growable: false),
        'reportSummaries': data.reportSummariesByCampaign.values
            .map((summary) => summary.toMap())
            .toList(growable: false),
        'cachedAt': DateTime.now().toIso8601String(),
      });
    } catch (_) {}
  }

  Future<void> _reloadDashboardIntoState({bool invalidateCaches = true}) async {
    if (invalidateCaches) {
      _invalidateDashboardCaches();
    }
    final future = _loadDashboardData();
    if (!mounted) {
      _dashboardFuture = future;
      return;
    }
    setState(() {
      _dashboardFuture = future.then((data) {
        if (mounted) {
          setState(() => _cachedDashboard = data);
        }
        return data;
      });
    });
  }

  Future<void> _removeCampaignFromLocalState(String campaignId) async {
    final current = _cachedDashboard;
    if (current == null) {
      return;
    }
    final filteredCampaigns = current.campaigns
        .where((campaign) => campaign.campaignId != campaignId)
        .toList(growable: false);
    final filteredMetrics = Map<String, _SponsoredCampaignMetrics>.from(
      current.metricsByCampaign,
    )..remove(campaignId);
    final filteredSummaries = Map<String, _SponsoredCampaignReportSummary>.from(
      current.reportSummariesByCampaign,
    )..remove(campaignId);
    final next = _SponsoredDashboardData(
      campaigns: filteredCampaigns,
      metricsByCampaign: filteredMetrics,
      recentReports: current.recentReports,
      reportSummariesByCampaign: filteredSummaries,
    );
    if (mounted) {
      setState(() => _cachedDashboard = next);
    } else {
      _cachedDashboard = next;
    }
    await _persistCachedDashboard(next);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required by AutomaticKeepAliveClientMixin
    final t = widget.t;
    final theme = Theme.of(context);
    final tabController = _safeTabController;

    return Directionality(
      textDirection: widget.textDirection,
      child: Column(
        children: [
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
                    text: t('adminNavSponsoredAds'),
                  ),
                  Tab(
                    icon: Icon(
                      _editingCampaignId == null
                          ? Icons.add_circle_outline
                          : Icons.edit_outlined,
                    ),
                    // Dedicated keys, not the generic `generalAdd`/`generalEdit`.
                    // A Match Inspector migration overwrote generalAdd with
                    // "Select User", which made this tab render as "Select User".
                    text: _editingCampaignId == null
                        ? t('adminSponsoredAdsTabAdd')
                        : t('adminSponsoredAdsTabEdit'),
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
                _buildEditorTab(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorTab(BuildContext context) {
    final t = widget.t;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        if (_serverConfigHydrated && !_adsEnabled) ...[
          _buildAdsDisabledBanner(),
          const SizedBox(height: 16),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_isLoadingEditor)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: LinearProgressIndicator(),
                  ),
                Text(
                  _editingCampaignPreview == null
                      ? t('adminSponsoredAdsSaveNew')
                      : (_editingCampaignPreview!.headlinePreview.isEmpty
                            ? _editingCampaignPreview!.internalName
                            : _editingCampaignPreview!.headlinePreview),
                  style: theme.textTheme.titleLarge,
                  textDirection: _editingCampaignPreview == null
                      ? null
                      : _textDirectionFor(
                          _editingCampaignPreview!.headlinePreview.isEmpty
                              ? _editingCampaignPreview!.internalName
                              : _editingCampaignPreview!.headlinePreview,
                        ),
                ),
                if (_editingCampaignPreview != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${_editingCampaignPreview!.advertiserName} · ${_editingCampaignPreview!.destinationUrl}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (_editingCampaignPreview != null) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildStatusBadge(
                        _statusLabel(_editingCampaignPreview!.moderationStatus),
                        _editingCampaignPreview!.moderationStatus == 'approved'
                            ? Colors.green
                            : _editingCampaignPreview!.moderationStatus ==
                                  'paused'
                            ? Colors.orange
                            : Colors.blueGrey,
                      ),
                      ..._selectedPlacements.map(
                        (placement) => _buildStatusBadge(
                          _placementLabel(placement),
                          Colors.indigo,
                        ),
                      ),
                      _buildStatusBadge(
                        _platformLabel(_editingCampaignPreview!.platform),
                        Colors.teal,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildCampaignForm(context),
        const SizedBox(height: 24),
        _buildFormActionButtons(context),
      ],
    );
  }

  Widget _buildCampaignsTab(BuildContext context) {
    // Hydrate config if needed (idempotent) - ensures _adsEnabled is synced with _cachedConfig
    if (_cachedConfig != null && !_configHydrated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _hydrateConfig(_cachedConfig!, fromServer: true);
      });
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        // Show disabled banner only when server has confirmed ads are disabled
        if (_serverConfigHydrated && !_adsEnabled) ...[
          _buildAdsDisabledBanner(),
          const SizedBox(height: 16),
        ],
        _buildDashboardCard(context),
      ],
    );
  }

  Widget _buildControlsTab(BuildContext context) {
    // Hydrate config if needed (idempotent) - ensures _adsEnabled is synced with _cachedConfig
    if (_cachedConfig != null && !_configHydrated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _hydrateConfig(_cachedConfig!, fromServer: true);
      });
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        if (!_adsEnabled) ...[
          _buildAdsDisabledBanner(),
          const SizedBox(height: 16),
        ],
        _buildAdConfigCard(context),
      ],
    );
  }

  Widget _buildAnalyticsTab(BuildContext context) {
    final t = widget.t;

    // Hydrate config if needed (idempotent) - ensures _adsEnabled is synced with _cachedConfig
    if (_cachedConfig != null && !_configHydrated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _hydrateConfig(_cachedConfig!, fromServer: true);
      });
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        // Show disabled banner only when server has confirmed ads are disabled
        if (_serverConfigHydrated && !_adsEnabled) ...[
          _buildAdsDisabledBanner(),
          const SizedBox(height: 16),
        ],
        // Use cached data for immediate updates (local increments), fall back to FutureBuilder for initial load
        FutureBuilder<_SponsoredDashboardData>(
          future: _safeDashboardFuture,
          builder: (context, snapshot) {
            // Prefer cached data (includes local realtime increments) over stale snapshot data
            final data =
                _cachedDashboard ??
                snapshot.data ??
                const _SponsoredDashboardData();

            // Show loading indicator if we have no data yet
            if (data.campaigns.isEmpty &&
                snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              );
            }

            if (snapshot.hasError && data.campaigns.isEmpty) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('adminSponsoredAdsLoadFailed')),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: _refresh,
                        child: Text(t('generalRetry')),
                      ),
                    ],
                  ),
                ),
              );
            }

            // Sort campaigns by impressions for display
            final rankedCampaigns = [...data.campaigns]
              ..sort((a, b) {
                final aMetrics = data.metricsByCampaign[a.campaignId];
                final bMetrics = data.metricsByCampaign[b.campaignId];
                return (bMetrics?.impressions ?? 0).compareTo(
                  aMetrics?.impressions ?? 0,
                );
              });

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _buildAnalyticsSummary(context, data),
                  ),
                ),
                const SizedBox(height: 16),
                if (rankedCampaigns.isNotEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: rankedCampaigns
                            .take(5)
                            .map(
                              (campaign) => _buildCampaignCard(
                                campaign,
                                data.metricsByCampaign[campaign.campaignId],
                                data.reportSummariesByCampaign[campaign
                                    .campaignId],
                                compactAnalyticsView: true,
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildAdConfigCard(BuildContext context) {
    final t = widget.t;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _configHydrated
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: 280,
                        child: _buildToggleTile(
                          label: t('adminSponsoredAdsConfigEnabled'),
                          value: _adsEnabled,
                          onChanged: (value) {
                            setState(() {
                              _adsEnabled = value;
                              _markConfigEdited();
                            });
                          },
                        ),
                      ),
                      _buildControlsDisabledState(
                        enabled: _adsEnabled,
                        child: SizedBox(
                          width: 280,
                          child: _buildToggleTile(
                            label: t('adminSponsoredAdsConfigSponsoredCards'),
                            value: _sponsoredCardsEnabled,
                            onChanged: (value) => setState(() {
                              _sponsoredCardsEnabled = value;
                              _markConfigEdited();
                            }),
                          ),
                        ),
                      ),
                      _buildControlsDisabledState(
                        enabled: _adsEnabled,
                        child: SizedBox(
                          width: 280,
                          child: _buildToggleTile(
                            label: t('adminSponsoredAdsConfigFamilySafe'),
                            value: _familySafeOnly,
                            onChanged: (value) => setState(() {
                              _familySafeOnly = value;
                              _markConfigEdited();
                            }),
                          ),
                        ),
                      ),
                      _buildControlsDisabledState(
                        enabled: _adsEnabled,
                        child: SizedBox(
                          width: 280,
                          child: _buildToggleTile(
                            label: t('adminSponsoredAdsConfigReports'),
                            value: _reportEnabled,
                            onChanged: (value) => setState(() {
                              _reportEnabled = value;
                              _markConfigEdited();
                            }),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _buildControlsDisabledState(
                        enabled: _adsEnabled,
                        child: SizedBox(
                          width: 220,
                          child: _buildTextField(
                            controller: _maxImpressionsController,
                            label: t('adminSponsoredAdsConfigMaxPerSession'),
                            keyboardType: TextInputType.number,
                            enabled: _adsEnabled,
                            onChanged: (_) => _handleConfigTextFieldChanged(),
                          ),
                        ),
                      ),
                      _buildControlsDisabledState(
                        enabled: _adsEnabled,
                        child: SizedBox(
                          width: 220,
                          child: _buildTextField(
                            controller: _minMinutesController,
                            label: t('adminSponsoredAdsConfigMinMinutes'),
                            keyboardType: TextInputType.number,
                            enabled: _adsEnabled,
                            onChanged: (_) => _handleConfigTextFieldChanged(),
                          ),
                        ),
                      ),
                      _buildControlsDisabledState(
                        enabled: _adsEnabled,
                        child: SizedBox(
                          width: 220,
                          child: _buildTextField(
                            controller: _firstDelaySecondsController,
                            label: t('adminSponsoredAdsConfigFirstDelay'),
                            keyboardType: TextInputType.number,
                            enabled: _adsEnabled,
                            onChanged: (_) => _handleConfigTextFieldChanged(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 16),
                  Text(
                    t('adminInternalAdsMasterControlsTitle'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t('adminInternalAdsMasterControlsSubtitle'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Master Placements
                  _buildControlsDisabledState(
                    enabled: _adsEnabled,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('adminInternalAdsAllowedPlacements'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            _buildMasterPlacementChip(
                              'home_inline',
                              t('adminSponsoredAdsPlacementHome'),
                            ),
                            _buildMasterPlacementChip(
                              'matches_inline',
                              t('adminSponsoredAdsPlacementMatches'),
                            ),
                            _buildMasterPlacementChip(
                              'chats_inline',
                              t('adminSponsoredAdsPlacementChats'),
                            ),
                            _buildMasterPlacementChip(
                              'events_inline',
                              t('adminSponsoredAdsPlacementEvents'),
                            ),
                            _buildMasterPlacementChip(
                              'profile_inline',
                              t('adminSponsoredAdsPlacementProfile'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Master Platforms
                  _buildControlsDisabledState(
                    enabled: _adsEnabled,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('adminInternalAdsAllowedPlatforms'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            _buildMasterPlatformChip(
                              'android',
                              t('adminSponsoredAdsPlatformAndroid'),
                            ),
                            _buildMasterPlatformChip(
                              'ios',
                              t('adminSponsoredAdsPlatformIos'),
                            ),
                            _buildMasterPlatformChip(
                              'web',
                              t('adminSponsoredAdsPlatformWeb'),
                            ),
                            _buildMasterPlatformChip(
                              'windows',
                              t('adminSponsoredAdsPlatformWindows'),
                            ),
                            _buildMasterPlatformChip(
                              'macos',
                              t('adminSponsoredAdsPlatformMacos'),
                            ),
                            _buildMasterPlatformChip(
                              'linux',
                              t('adminSponsoredAdsPlatformLinux'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Master Tiers
                  _buildControlsDisabledState(
                    enabled: _adsEnabled,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('adminInternalAdsAllowedTiers'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            _buildMasterTierChip(
                              'free',
                              t('adminSubscriptionTierFree'),
                            ),
                            _buildMasterTierChip('plus', t('tierPlus')),
                            _buildMasterTierChip('gold', t('tierGold')),
                            _buildMasterTierChip('platinum', t('tierPlatinum')),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (!_configVerified) ...[
                    _buildConfigUnverifiedWarning(context),
                    const SizedBox(height: 16),
                  ],
                  if (_hasConfigChanges)
                    ElevatedButton.icon(
                      onPressed: _isSavingConfig || !_configVerified
                          ? null
                          : _saveAdConfig,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(t('adminSponsoredAdsConfigSave')),
                    ),
                ],
              )
            : FutureBuilder<_SponsoredAdConfigState>(
                future: _safeAdConfigFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }

                  // Hydrate in a post-frame callback. Calling _hydrateConfig
                  // inline here mutated the master Sets and the numeric
                  // TextEditingControllers during build, which is an impure
                  // build and can trip "setState/markNeedsBuild during build"
                  // when a controller listener fires.
                  if (snapshot.hasData && !_configHydrated) {
                    final data = snapshot.data!;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _hydrateConfig(data, fromServer: true);
                    });
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

  Widget _buildMasterPlacementChip(String value, String label) {
    final isSelected = _masterAllowedPlacements.contains(value);
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: _adsEnabled
          ? (selected) {
              setState(() {
                if (selected) {
                  _masterAllowedPlacements.add(value);
                } else {
                  // Prevent removing the last placement
                  if (_masterAllowedPlacements.length > 1) {
                    _masterAllowedPlacements.remove(value);
                  }
                }
                _markConfigEdited();
              });
            }
          : null,
    );
  }

  Widget _buildMasterPlatformChip(String value, String label) {
    final isSelected = _masterAllowedPlatforms.contains(value);
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: _adsEnabled
          ? (selected) {
              setState(() {
                if (selected) {
                  _masterAllowedPlatforms.add(value);
                } else {
                  // Prevent removing the last platform
                  if (_masterAllowedPlatforms.length > 1) {
                    _masterAllowedPlatforms.remove(value);
                  }
                }
                _normalizeSelectedPlatforms();
                _markConfigEdited();
              });
            }
          : null,
    );
  }

  Widget _buildMasterTierChip(String value, String label) {
    final isSelected = _masterAllowedTiers.contains(value);
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: _adsEnabled
          ? (selected) {
              setState(() {
                if (selected) {
                  _masterAllowedTiers.add(value);
                } else {
                  // Prevent removing the last tier
                  if (_masterAllowedTiers.length > 1) {
                    _masterAllowedTiers.remove(value);
                  }
                }
                _markConfigEdited();
              });
            }
          : null,
    );
  }

  Widget _buildPlacementChip(String value, String label) {
    final isMasterAllowed = _masterAllowedPlacements.contains(value);
    final isSelected = _selectedPlacements.contains(value);

    return Tooltip(
      message: isMasterAllowed
          ? ''
          : widget.t('adminInternalAdsPlacementDisabledByMaster'),
      child: FilterChip(
        label: Text(label),
        selected: isSelected && isMasterAllowed,
        onSelected: isMasterAllowed
            ? (selected) {
                setState(() {
                  if (selected) {
                    _selectedPlacements.add(value);
                  } else {
                    if (_selectedPlacements.length > 1) {
                      _selectedPlacements.remove(value);
                    }
                  }
                });
              }
            : null,
        backgroundColor: isMasterAllowed ? null : Colors.grey.shade200,
        disabledColor: Colors.grey.shade100,
      ),
    );
  }

  Widget _buildPlatformChip(String value, String label) {
    final t = widget.t;
    final isMasterAllowed = value == 'all'
        ? _masterAllowedPlatforms.isNotEmpty
        : _masterAllowedPlatforms.contains(value);
    final isAllChip = value == 'all';
    final isSelected = isAllChip
        ? _masterAllowedPlatforms.every(_selectedPlatforms.contains)
        : _selectedPlatforms.contains(value) && isMasterAllowed;

    return Tooltip(
      message: isMasterAllowed
          ? ''
          : t('adminInternalAdsPlatformDisabledByMaster'),
      child: FilterChip(
        label: Text(label),
        selected: isSelected,
        onSelected: isMasterAllowed
            ? (selected) {
                setState(() {
                  if (isAllChip) {
                    if (selected) {
                      _selectedPlatforms
                        ..clear()
                        ..addAll(_masterAllowedPlatforms);
                    }
                  } else {
                    _selectedPlatforms.remove('all');
                    if (selected) {
                      _selectedPlatforms.add(value);
                    } else if (_selectedPlatforms.length > 1) {
                      _selectedPlatforms.remove(value);
                    }
                  }
                  _normalizeSelectedPlatforms();
                });
              }
            : null,
        backgroundColor: isMasterAllowed ? null : Colors.grey.shade200,
        disabledColor: Colors.grey.shade100,
      ),
    );
  }

  Widget _buildTierChip(String value, String label) {
    final t = widget.t;
    final isMasterAllowed = _masterAllowedTiers.contains(value);
    final isSelected = _selectedTiers.contains(value);
    // Allow interaction if master allowed OR already selected (can deselect)
    final canInteract = isMasterAllowed || isSelected;

    return Tooltip(
      message: isMasterAllowed
          ? ''
          : isSelected
          ? t('adminInternalAdsTierNotInMaster')
          : t('adminInternalAdsTierDisabledByMaster'),
      child: FilterChip(
        label: Text(label),
        selected: isSelected,
        onSelected: canInteract
            ? (selected) {
                setState(() {
                  if (selected) {
                    _selectedTiers.add(value);
                  } else if (_selectedTiers.length > 1) {
                    _selectedTiers.remove(value);
                  }
                  _normalizeSelectedTiers();
                });
              }
            : null,
        backgroundColor: isMasterAllowed ? null : Colors.grey.shade200,
        disabledColor: Colors.grey.shade100,
      ),
    );
  }

  void _normalizeSelectedTiers() {
    // Only remove non-master tiers when creating NEW campaign (at pristine shell)
    // When editing, preserve all selected tiers even if not in master list
    if (_isEditorAtPristineShell()) {
      _selectedTiers.removeWhere((tier) => !_masterAllowedTiers.contains(tier));
    }
    if (_selectedTiers.isEmpty && _masterAllowedTiers.isNotEmpty) {
      _selectedTiers.add(_masterAllowedTiers.first);
    }
  }

  Widget _buildDashboardCard(BuildContext context) {
    final t = widget.t;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: t('adminSponsoredAdsSearchHint'),
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.clear),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildFilterChip(
                  label: t('adminSponsoredAdsFilterAll'),
                  filter: _SponsoredCampaignFilter.all,
                ),
                _buildFilterChip(
                  label: t('adminSponsoredAdsFilterApproved'),
                  filter: _SponsoredCampaignFilter.approved,
                ),
                _buildFilterChip(
                  label: t('adminSponsoredAdsFilterDraft'),
                  filter: _SponsoredCampaignFilter.draft,
                ),
                _buildFilterChip(
                  label: t('adminSponsoredAdsFilterPaused'),
                  filter: _SponsoredCampaignFilter.paused,
                ),
                _buildFilterChip(
                  label: t('adminSponsoredAdsFilterRejected'),
                  filter: _SponsoredCampaignFilter.rejected,
                ),
                _buildFilterChip(
                  label: t('adminSponsoredAdsFilterDisabled'),
                  filter: _SponsoredCampaignFilter.disabled,
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_cachedDashboard != null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_applyFilters(_cachedDashboard!.campaigns).isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(t('adminSponsoredAdsEmpty')),
                    )
                  else
                    Column(
                      children: _applyFilters(_cachedDashboard!.campaigns)
                          .map(
                            (campaign) => _buildCampaignCard(
                              campaign,
                              _cachedDashboard!.metricsByCampaign[campaign
                                  .campaignId],
                              _cachedDashboard!
                                  .reportSummariesByCampaign[campaign
                                  .campaignId],
                              compactAnalyticsView: false,
                            ),
                          )
                          .toList(growable: false),
                    ),
                ],
              )
            else
              FutureBuilder<_SponsoredDashboardData>(
                future: _safeDashboardFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }

                  if (snapshot.hasError) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t('adminSponsoredAdsLoadFailed')),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: _refresh,
                            child: Text(t('generalRetry')),
                          ),
                        ],
                      ),
                    );
                  }

                  final data = snapshot.data ?? const _SponsoredDashboardData();
                  final campaigns = _applyFilters(data.campaigns);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (campaigns.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(t('adminSponsoredAdsEmpty')),
                        )
                      else
                        Column(
                          children: campaigns
                              .map(
                                (campaign) => _buildCampaignCard(
                                  campaign,
                                  data.metricsByCampaign[campaign.campaignId],
                                  data.reportSummariesByCampaign[campaign
                                      .campaignId],
                                  compactAnalyticsView: false,
                                ),
                              )
                              .toList(growable: false),
                        ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCampaignForm(BuildContext context) {
    final t = widget.t;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFormCard(
          context: context,
          title: t('adminSponsoredAdsFormSectionCampaign'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTextField(
                controller: _internalNameController,
                label: t('adminSponsoredAdsInternalName'),
              ),
              const SizedBox(height: 12),
              _buildTextField(
                controller: _advertiserNameController,
                label: t('adminSponsoredAdsAdvertiserName'),
              ),
              const SizedBox(height: 12),
              _buildTextField(
                controller: _destinationUrlController,
                label: t('adminSponsoredAdsDestinationUrl'),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              _buildTextField(
                controller: _imageUrlController,
                label: t('adminSponsoredAdsImageUrl'),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              _buildImageSection(context),
              const SizedBox(height: 12),
              _buildTextField(
                controller: _sortPriorityController,
                label: t('adminSponsoredAdsSortPriority'),
                helperText: t('adminSponsoredAdsSortPriorityHint'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 220,
                    child: _buildTextField(
                      controller: _dailyImpressionCapController,
                      label: t('adminSponsoredAdsDailyCap'),
                      helperText: t('adminSponsoredAdsLeaveEmptyForNoLimit'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: _buildTextField(
                      controller: _totalImpressionCapController,
                      label: t('adminSponsoredAdsTotalCap'),
                      helperText: t('adminSponsoredAdsLeaveEmptyForNoLimit'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 240,
                    child: _buildDropdownField(
                      label: t('adminSponsoredAdsModerationStatus'),
                      value: _moderationStatus,
                      items: {
                        'draft': t('adminSponsoredAdsStatusDraft'),
                        'approved': t('adminSponsoredAdsStatusApproved'),
                        'rejected': t('adminSponsoredAdsStatusRejected'),
                        'paused': t('adminSponsoredAdsStatusPaused'),
                      },
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _moderationStatus = value);
                        }
                      },
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('adminSponsoredAdsPlacements'),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            _buildPlacementChip(
                              'home_inline',
                              t('adminSponsoredAdsPlacementHome'),
                            ),
                            _buildPlacementChip(
                              'matches_inline',
                              t('adminSponsoredAdsPlacementMatches'),
                            ),
                            _buildPlacementChip(
                              'chats_inline',
                              t('adminSponsoredAdsPlacementChats'),
                            ),
                            _buildPlacementChip(
                              'events_inline',
                              t('adminSponsoredAdsPlacementEvents'),
                            ),
                            _buildPlacementChip(
                              'profile_inline',
                              t('adminSponsoredAdsPlacementProfile'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildPlatformChip(
                        'all',
                        t('adminSponsoredAdsPlatformAll'),
                      ),
                      _buildPlatformChip(
                        'android',
                        t('adminSponsoredAdsPlatformAndroid'),
                      ),
                      _buildPlatformChip(
                        'ios',
                        t('adminSponsoredAdsPlatformIos'),
                      ),
                      _buildPlatformChip(
                        'web',
                        t('adminSponsoredAdsPlatformWeb'),
                      ),
                      _buildPlatformChip(
                        'windows',
                        t('adminSponsoredAdsPlatformWindows'),
                      ),
                      _buildPlatformChip(
                        'macos',
                        t('adminSponsoredAdsPlatformMacos'),
                      ),
                      _buildPlatformChip(
                        'linux',
                        t('adminSponsoredAdsPlatformLinux'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Tier Targeting
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('adminInternalAdsTargetTiers'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t('adminInternalAdsTargetTiersSubtitle'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildTierChip('free', t('adminSubscriptionTierFree')),
                      _buildTierChip('plus', t('tierPlus')),
                      _buildTierChip('gold', t('tierGold')),
                      _buildTierChip('platinum', t('tierPlatinum')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: Text(t('adminSponsoredAdsFamilySafe')),
                    selected: _familySafe,
                    onSelected: (value) => setState(() => _familySafe = value),
                  ),
                  FilterChip(
                    label: Text(t('adminSponsoredAdsCampaignActive')),
                    selected: _campaignActive,
                    onSelected: (value) =>
                        setState(() => _campaignActive = value),
                  ),
                  FilterChip(
                    label: Text(t('adminSponsoredAdsCreativeActive')),
                    selected: _creativeActive,
                    onSelected: (value) =>
                        setState(() => _creativeActive = value),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _buildDateButton(
                    label: t('adminSponsoredAdsStartsAt'),
                    value: _startsAt,
                    onTap: () async {
                      final picked = await _pickDateTime(
                        _startsAt ?? DateTime.now().toUtc(),
                      );
                      if (picked != null) {
                        setState(() => _startsAt = picked);
                      }
                    },
                    onClear: _startsAt == null
                        ? null
                        : () => setState(() => _startsAt = null),
                  ),
                  _buildDateButton(
                    label: t('adminSponsoredAdsEndsAt'),
                    value: _endsAt,
                    onTap: () async {
                      final picked = await _pickDateTime(
                        _endsAt ??
                            DateTime.now().toUtc().add(
                              const Duration(days: 30),
                            ),
                      );
                      if (picked != null) {
                        setState(() => _endsAt = picked);
                      }
                    },
                    onClear: _endsAt == null
                        ? null
                        : () => setState(() => _endsAt = null),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _startsAt == null
                    ? t('adminSponsoredAdsStartsAtHintEmpty')
                    : _startsAt!.isAfter(DateTime.now().toUtc())
                    ? t('adminSponsoredAdsStartsAtHintFuture')
                    : t('adminSponsoredAdsStartsAtHintNow'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color:
                      _startsAt != null &&
                          _startsAt!.isAfter(DateTime.now().toUtc())
                      ? Colors.orange.shade800
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _buildFormCard(
          context: context,
          title: t('adminSponsoredAdsFormSectionCreative'),
          child: _buildLocaleEditor(),
        ),
      ],
    );
  }

  Widget _buildFormActionButtons(BuildContext context) {
    final t = widget.t;
    final showActionButtons =
        _hasUnsavedEditorChanges || _editingCampaignId != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('adminSponsoredAdsFormActions'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            if (showActionButtons)
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  if (_hasUnsavedEditorChanges) ...[
                    FilledButton.icon(
                      onPressed: _isSaving || _isLoadingEditor
                          ? null
                          : _saveCampaign,
                      icon: Icon(
                        _editingCampaignId == null
                            ? Icons.add_circle_outline
                            : Icons.save_outlined,
                      ),
                      label: Text(
                        _editingCampaignId == null
                            ? t('adminSponsoredAdsSaveNew')
                            : t('adminSponsoredAdsSaveChanges'),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _isSaving || _isLoadingEditor
                          ? null
                          : _applyDemoPreset,
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: Text(t('adminSponsoredAdsUseDemoPreset')),
                    ),
                  ],
                  if (_editingCampaignId != null)
                    OutlinedButton(
                      onPressed: _isSaving || _isLoadingEditor
                          ? null
                          : _cancelEditing,
                      child: Text(t('generalCancel')),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormCard({
    required BuildContext context,
    required String title,
    required Widget child,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildLocaleEditor() {
    final t = widget.t;
    return FutureBuilder<List<_SponsoredLocaleOption>>(
      future: _safeLocaleOptionsFuture,
      builder: (context, snapshot) {
        final options = snapshot.data ?? _availableLocaleOptions;
        final completedCount = _orderedSelectedLocaleCodes()
            .where(_isLocaleComplete)
            .length;
        final missingCount = _selectedLocaleCodes.length - completedCount;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('adminSponsoredAdsLocalesHelp'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _buildLocaleSummaryStat(
                  label: t('adminSponsoredAdsLocalesSelected'),
                  value: _selectedLocaleCodes.length.toString(),
                  icon: Icons.language_outlined,
                ),
                _buildLocaleSummaryStat(
                  label: t('adminSponsoredAdsLocalesCompleted'),
                  value: completedCount.toString(),
                  icon: Icons.check_circle_outline,
                ),
                _buildLocaleSummaryStat(
                  label: t('adminSponsoredAdsLocalesMissing'),
                  value: missingCount.toString(),
                  icon: Icons.pending_outlined,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _orderedSelectedLocaleCodes()
                        .map((code) => _buildSelectedLocaleChip(code))
                        .toList(growable: false),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => _showAddLocaleDialog(options),
                  icon: const Icon(Icons.add_circle_outline),
                  label: Text(t('adminSponsoredAdsLocalesAdd')),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ..._orderedSelectedLocaleCodes().map(
              (code) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildLocaleEditorCard(code),
              ),
            ),
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

  /// Shown when the config could not be read from the server in full. Saving is
  /// disabled because the visible values may be client-side defaults, and
  /// writing them back would silently revert real production settings.
  Widget _buildConfigUnverifiedWarning(BuildContext context) {
    final t = widget.t;
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.tertiaryContainer,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              color: theme.colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('adminSponsoredAdsConfigUnverified'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _isSavingConfig ? null : _refresh,
                    icon: const Icon(Icons.refresh),
                    label: Text(t('generalRetry')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _orderedSelectedLocaleCodes() {
    final codes = _selectedLocaleCodes.toList(growable: false);
    codes.sort((a, b) {
      if (a == 'en') return -1;
      if (b == 'en') return 1;
      return _localeDisplayName(a).compareTo(_localeDisplayName(b));
    });
    return codes;
  }

  String _localeDisplayName(String localeCode) {
    final normalized = localeCode.trim().toLowerCase();
    for (final option in _availableLocaleOptions) {
      if (option.code == normalized && option.displayName.trim().isNotEmpty) {
        return option.displayName;
      }
    }
    final t = widget.t;
    return switch (normalized) {
      'en' => t('adminIntentsInterestsLocaleEn'),
      'es' => t('adminIntentsInterestsLocaleEs'),
      'he' => t('adminIntentsInterestsLocaleHe'),
      _ => normalized.toUpperCase(),
    };
  }

  /// Controllers backing [localeCode]'s four copy fields.
  ///
  /// en/es/he borrow the long-lived controllers. Any other locale gets a
  /// dedicated [_SponsoredLocaleInputs] created on demand. Callers that only
  /// read during build should use [_peekLocaleInputsFor], which never mutates
  /// `_extraLocaleInputs` — creating a controller mid-build is a side effect
  /// and can collide with [_clearExtraLocaleInputs] disposing it from a
  /// setState callback.
  _SponsoredLocaleInputs _localeInputsFor(String localeCode) {
    final normalized = localeCode.trim().toLowerCase();
    switch (normalized) {
      case 'en':
        return _SponsoredLocaleInputs.borrowed(
          headline: _headlineEnController,
          body: _bodyEnController,
          cta: _ctaEnController,
          sponsor: _sponsorEnController,
        );
      case 'es':
        return _SponsoredLocaleInputs.borrowed(
          headline: _headlineEsController,
          body: _bodyEsController,
          cta: _ctaEsController,
          sponsor: _sponsorEsController,
        );
      case 'he':
        return _SponsoredLocaleInputs.borrowed(
          headline: _headlineHeController,
          body: _bodyHeController,
          cta: _ctaHeController,
          sponsor: _sponsorHeController,
        );
      default:
        return _extraLocaleInputs.putIfAbsent(
          normalized,
          _SponsoredLocaleInputs.create,
        );
    }
  }

  /// Read-only variant of [_localeInputsFor]. Returns an empty, non-owned
  /// [_SponsoredLocaleInputs] for a locale whose controllers do not exist yet,
  /// so build-time readers never allocate. Always treat the result as
  /// non-owning; never dispose it.
  _SponsoredLocaleInputs _peekLocaleInputsFor(String localeCode) {
    final normalized = localeCode.trim().toLowerCase();
    if (normalized == 'en' || normalized == 'es' || normalized == 'he') {
      return _localeInputsFor(normalized);
    }
    return _extraLocaleInputs[normalized] ?? _SponsoredLocaleInputs.empty();
  }

  bool _isLocaleComplete(String localeCode) {
    final inputs = _peekLocaleInputsFor(localeCode);
    return inputs.headline.text.trim().isNotEmpty &&
        inputs.body.text.trim().isNotEmpty &&
        inputs.cta.text.trim().isNotEmpty &&
        inputs.sponsor.text.trim().isNotEmpty;
  }

  bool _isLocaleEmpty(String localeCode) {
    final inputs = _peekLocaleInputsFor(localeCode);
    return inputs.headline.text.trim().isEmpty &&
        inputs.body.text.trim().isEmpty &&
        inputs.cta.text.trim().isEmpty &&
        inputs.sponsor.text.trim().isEmpty;
  }

  String _localeStatusLabel(String localeCode) {
    final t = widget.t;
    if (_isLocaleComplete(localeCode)) {
      return t('adminSponsoredAdsLocaleStatusComplete');
    }
    return t('adminSponsoredAdsLocaleStatusMissing');
  }

  Widget _buildLocaleSummaryStat({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return _buildInlineMetricStat(label: label, value: value, icon: icon);
  }

  Widget _buildSelectedLocaleChip(String localeCode) {
    final canRemove = localeCode != 'en';
    final isComplete = _isLocaleComplete(localeCode);
    return InputChip(
      label: Text(
        '${_localeDisplayName(localeCode)}'
        '${isComplete ? '' : ' · ${widget.t('adminSponsoredAdsLocaleStatusMissing')}'}',
      ),
      selected: _expandedLocaleCodes.contains(localeCode),
      onPressed: () {
        setState(() {
          if (_expandedLocaleCodes.contains(localeCode)) {
            _expandedLocaleCodes.remove(localeCode);
          } else {
            _expandedLocaleCodes.add(localeCode);
          }
        });
      },
      onDeleted: canRemove ? () => _removeLocale(localeCode) : null,
    );
  }

  Widget _buildLocaleEditorCard(String localeCode) {
    final t = widget.t;
    final theme = Theme.of(context);
    final inputs = _localeInputsFor(localeCode);
    final expanded = _expandedLocaleCodes.contains(localeCode);
    final canRemove = localeCode != 'en';
    final isRtl = _isRtlLocale(localeCode);
    final localeDirection = isRtl ? TextDirection.rtl : TextDirection.ltr;

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        initiallyExpanded: expanded,
        onExpansionChanged: (value) {
          setState(() {
            if (value) {
              _expandedLocaleCodes.add(localeCode);
            } else {
              _expandedLocaleCodes.remove(localeCode);
            }
          });
        },
        title: Text(_localeDisplayName(localeCode)),
        subtitle: Text(
          '${t('adminSponsoredAdsLocalesCode')}: ${localeCode.toUpperCase()} · ${_localeStatusLabel(localeCode)}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (localeCode == 'en')
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _buildStatusBadge(
                  t('adminSponsoredAdsLocalePrimary'),
                  Colors.indigo,
                ),
              ),
            if (canRemove)
              IconButton(
                onPressed: () => _removeLocale(localeCode),
                tooltip: t('adminSponsoredAdsLocaleRemove'),
                icon: const Icon(Icons.delete_outline),
              ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t('adminSponsoredAdsLocalesSectionHint'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (localeCode != 'en') ...[
                TextButton.icon(
                  onPressed: () => _copyEnglishToLocale(localeCode),
                  icon: const Icon(Icons.copy_outlined),
                  label: Text(t('adminSponsoredAdsLocaleCopyEnglish')),
                ),
                TextButton.icon(
                  onPressed: () => _clearLocale(localeCode),
                  icon: const Icon(Icons.clear_outlined),
                  label: Text(t('adminSponsoredAdsLocaleClear')),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          _buildTextField(
            controller: inputs.headline,
            label:
                '${t('adminSponsoredAdsLocaleFieldHeadline')} (${_localeDisplayName(localeCode)})',
            onChanged: (_) => setState(() {}),
            textAlign: isRtl ? TextAlign.right : TextAlign.left,
            textDirection: localeDirection,
          ),
          const SizedBox(height: 12),
          _buildTextField(
            controller: inputs.body,
            label:
                '${t('adminSponsoredAdsLocaleFieldBody')} (${_localeDisplayName(localeCode)})',
            maxLines: 3,
            onChanged: (_) => setState(() {}),
            textAlign: isRtl ? TextAlign.right : TextAlign.left,
            textDirection: localeDirection,
          ),
          const SizedBox(height: 12),
          _buildTextField(
            controller: inputs.cta,
            label:
                '${t('adminSponsoredAdsLocaleFieldCta')} (${_localeDisplayName(localeCode)})',
            onChanged: (_) => setState(() {}),
            textAlign: isRtl ? TextAlign.right : TextAlign.left,
            textDirection: localeDirection,
          ),
          const SizedBox(height: 12),
          _buildTextField(
            controller: inputs.sponsor,
            label:
                '${t('adminSponsoredAdsLocaleFieldSponsor')} (${_localeDisplayName(localeCode)})',
            onChanged: (_) => setState(() {}),
            textAlign: isRtl ? TextAlign.right : TextAlign.left,
            textDirection: localeDirection,
          ),
        ],
      ),
    );
  }

  Future<void> _showAddLocaleDialog(
    List<_SponsoredLocaleOption> options,
  ) async {
    final t = widget.t;
    final searchController = TextEditingController();
    var filtered = _availableLocalesForSelection(options);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void applyFilter(String query) {
              final normalized = query.trim().toLowerCase();
              filtered = _availableLocalesForSelection(options)
                  .where((option) {
                    return option.code.contains(normalized) ||
                        option.displayName.toLowerCase().contains(normalized);
                  })
                  .toList(growable: false);
            }

            return AlertDialog(
              title: Text(t('adminSponsoredAdsLocalesAdd')),
              content: SizedBox(
                width: 460,
                height: 420,
                child: Column(
                  children: [
                    TextField(
                      controller: searchController,
                      decoration: InputDecoration(
                        labelText: t('adminSponsoredAdsLocalesSearchHint'),
                        prefixIcon: const Icon(Icons.search),
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (value) {
                        setDialogState(() {
                          applyFilter(value);
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text(
                                t('adminSponsoredAdsLocalesEmptyState'),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final option = filtered[index];
                                return ListTile(
                                  title: Text(option.displayName),
                                  subtitle: Text(option.code.toUpperCase()),
                                  onTap: () {
                                    Navigator.of(dialogContext).pop();
                                    _addLocale(option.code);
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(t('generalCancel')),
                ),
              ],
            );
          },
        );
      },
    );
    searchController.dispose();
  }

  List<_SponsoredLocaleOption> _availableLocalesForSelection(
    List<_SponsoredLocaleOption> options,
  ) {
    final normalizedOptions = options.isEmpty ? _defaultLocaleOptions : options;
    return normalizedOptions
        .where((option) => !_selectedLocaleCodes.contains(option.code))
        .toList(growable: false);
  }

  void _addLocale(String localeCode) {
    final normalized = localeCode.trim().toLowerCase();
    setState(() {
      _selectedLocaleCodes.add(normalized);
      _expandedLocaleCodes.add(normalized);
      _localeInputsFor(normalized);
    });
  }

  void _removeLocale(String localeCode) {
    final normalized = localeCode.trim().toLowerCase();
    if (normalized == 'en') {
      return;
    }
    final extra = _extraLocaleInputs.remove(normalized);
    extra?.dispose();
    setState(() {
      _selectedLocaleCodes.remove(normalized);
      _expandedLocaleCodes.remove(normalized);
    });
  }

  void _clearLocale(String localeCode) {
    final inputs = _localeInputsFor(localeCode);
    setState(() {
      inputs.headline.clear();
      inputs.body.clear();
      inputs.cta.clear();
      inputs.sponsor.clear();
    });
  }

  void _copyEnglishToLocale(String localeCode) {
    if (localeCode == 'en') {
      return;
    }
    final english = _localeInputsFor('en');
    final target = _localeInputsFor(localeCode);
    setState(() {
      target.headline.text = english.headline.text.trim();
      target.body.text = english.body.text.trim();
      target.cta.text = english.cta.text.trim();
      target.sponsor.text = english.sponsor.text.trim();
    });
  }

  void _normalizeSelectedPlatforms() {
    // Only drop non-master platforms when composing a NEW campaign at the
    // pristine shell. When editing, the campaign's existing platforms must be
    // preserved even if the master list was narrowed, otherwise saving would
    // delete those creatives. Mirrors _normalizeSelectedTiers.
    if (_isEditorAtPristineShell()) {
      _selectedPlatforms.removeWhere(
        (platform) =>
            platform != 'all' && !_masterAllowedPlatforms.contains(platform),
      );
    }
    if (_selectedPlatforms.isEmpty && _masterAllowedPlatforms.isNotEmpty) {
      _selectedPlatforms.add(_masterAllowedPlatforms.first);
    }
  }

  void _clearExtraLocaleInputs() {
    try {
      for (final inputs in _extraLocaleInputs.values) {
        inputs.dispose();
      }
      _extraLocaleInputs.clear();
    } catch (_) {
      // Hot reload can preserve an older JS-backed state object whose field
      // shape no longer matches this class. Ignore and let hot restart recover.
    }
  }

  bool _isRtlLocale(String localeCode) {
    final normalized = localeCode.trim().toLowerCase();
    return normalized == 'he' ||
        normalized == 'ar' ||
        normalized == 'fa' ||
        normalized == 'ur';
  }

  TextDirection _textDirectionFor(String text) {
    for (var i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      if ((code >= 0x0590 && code <= 0x05FF) ||
          (code >= 0x0600 && code <= 0x06FF) ||
          (code >= 0xFB1D && code <= 0xFDFF) ||
          (code >= 0xFE70 && code <= 0xFEFF)) {
        return TextDirection.rtl;
      }
    }
    return TextDirection.ltr;
  }

  Widget _buildImageSection(BuildContext context) {
    final t = widget.t;
    final imageUrl = _imageUrlController.text.trim();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('adminSponsoredAdsImagePreviewTitle'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          if (imageUrl.isEmpty)
            Text(
              t('adminSponsoredAdsImageEmpty'),
              style: Theme.of(context).textTheme.bodyMedium,
            )
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                height: 180,
                width: double.infinity,
                fit: BoxFit.cover,
                errorWidget: (context, error, stackTrace) => Container(
                  height: 180,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: Text(t('adminSponsoredAdsImagePreviewFailed')),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              ElevatedButton.icon(
                onPressed: _isUploadingImage ? null : _uploadImage,
                icon: _isUploadingImage
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.upload_file_outlined),
                label: Text(t('adminSponsoredAdsUploadImage')),
              ),
              if (imageUrl.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: _isUploadingImage ? null : _clearImage,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(t('adminSponsoredAdsClearImage')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCampaignCard(
    _SponsoredCampaignRow campaign,
    _SponsoredCampaignMetrics? metrics,
    _SponsoredCampaignReportSummary? reportSummary, {
    required bool compactAnalyticsView,
  }) {
    final t = widget.t;
    final theme = Theme.of(context);

    return Card(
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: _editingCampaignId == campaign.campaignId
              ? theme.colorScheme.primary
              : Colors.transparent,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        campaign.headlinePreview.isEmpty
                            ? campaign.internalName
                            : campaign.headlinePreview,
                        style: theme.textTheme.titleMedium,
                        textDirection: _textDirectionFor(
                          campaign.headlinePreview.isEmpty
                              ? campaign.internalName
                              : campaign.headlinePreview,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        campaign.internalName,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildStatusBadge(
                            _statusLabel(campaign.moderationStatus),
                            campaign.moderationStatus == 'approved'
                                ? Colors.green
                                : campaign.moderationStatus == 'paused'
                                ? Colors.orange
                                : Colors.blueGrey,
                          ),
                          _buildEnabledBadge(campaign.isActive),
                          ...campaign.placements.map(
                            (placement) => _buildStatusBadge(
                              _placementLabel(placement),
                              Colors.indigo,
                            ),
                          ),
                          ...campaign.platforms.map(
                            (platform) => _buildStatusBadge(
                              _platformLabel(platform),
                              Colors.teal,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (_editingCampaignId == campaign.campaignId)
                  Icon(Icons.edit_outlined, color: theme.colorScheme.primary),
              ],
            ),
            const SizedBox(height: 12),
            if (compactAnalyticsView) ...[
              Text(
                campaign.advertiserName,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                campaign.destinationUrl,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
            ] else ...[
              Text(
                '${campaign.advertiserName} · ${campaign.destinationUrl}',
                style: theme.textTheme.bodyMedium,
              ),
              if (campaign.bodyPreview.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  campaign.bodyPreview,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (campaign.imageUrl.trim().isNotEmpty) ...[
                InkWell(
                  onTap: () => _showCampaignImagePreview(campaign),
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: campaign.imageUrl.trim(),
                          height: 140,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorWidget: (context, error, stackTrace) =>
                              const SizedBox.shrink(),
                        ),
                      ),
                      Positioned(
                        right: 10,
                        bottom: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.open_in_full,
                                size: 14,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                t('adminBroadcastsPreview'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ],
            _buildMetricDrilldownSection(campaign, metrics, reportSummary),
            const SizedBox(height: 12),
            if (!compactAnalyticsView) ...[
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  Text(
                    '${t('adminSponsoredAdsStartsAt')}: ${_formatDateTime(campaign.startsAt)}',
                  ),
                  Text(
                    '${t('adminSponsoredAdsEndsAt')}: ${_formatDateTime(campaign.endsAt)}',
                  ),
                  Text(
                    '${t('adminSponsoredAdsSortPriority')}: ${campaign.sortPriority}',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: () => _loadForEditing(campaign),
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(t('generalEdit')),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _toggleCampaignActive(campaign),
                    icon: Icon(
                      campaign.isActive
                          ? Icons.block_outlined
                          : Icons.check_circle_outline,
                    ),
                    label: Text(
                      campaign.isActive
                          ? t('adminSponsoredAdsDisableAction')
                          : t('adminSponsoredAdsEnableAction'),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _deleteCampaign(campaign),
                    icon: const Icon(Icons.delete_outline),
                    label: Text(t('generalDelete')),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricDrilldownSection(
    _SponsoredCampaignRow campaign,
    _SponsoredCampaignMetrics? metrics,
    _SponsoredCampaignReportSummary? reportSummary,
  ) {
    final t = widget.t;
    final ctrValue = metrics == null
        ? '-'
        : '${metrics.ctrPercent.toStringAsFixed(2)}%';

    return LayoutBuilder(
      builder: (context, constraints) {
        final useFullRow = constraints.maxWidth >= 500;
        final itemWidth = useFullRow
            ? (constraints.maxWidth - 36) / 4
            : (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _buildInlineMetricStat(
              label: t('adminSponsoredAdsMetricImpressions'),
              value: (metrics?.impressions ?? 0).toString(),
              icon: Icons.visibility_outlined,
              width: itemWidth,
              onTap: () => _showCampaignEventDetails(
                campaign,
                eventType: 'impression',
                title: t('adminSponsoredAdsImpressionsDialogTitle'),
                totalCount: metrics?.impressions ?? 0,
              ),
            ),
            _buildInlineMetricStat(
              label: t('adminSponsoredAdsMetricClicks'),
              value: (metrics?.clicks ?? 0).toString(),
              icon: Icons.ads_click_outlined,
              width: itemWidth,
              onTap: () => _showCampaignEventDetails(
                campaign,
                eventType: 'click',
                title: t('adminSponsoredAdsClicksDialogTitle'),
                totalCount: metrics?.clicks ?? 0,
              ),
            ),
            _buildInlineMetricStat(
              label: t('adminSponsoredAdsMetricReports'),
              value: (reportSummary?.reportCount ?? metrics?.reports ?? 0)
                  .toString(),
              icon: Icons.flag_outlined,
              width: itemWidth,
              onTap: () =>
                  _showCampaignReportsOverview(campaign, reportSummary),
            ),
            _buildInlineMetricStat(
              label: t('adminSponsoredAdsMetricCtr'),
              value: ctrValue,
              icon: Icons.trending_up_outlined,
              width: itemWidth,
            ),
          ],
        );
      },
    );
  }

  Widget _buildReportOverviewSection(
    _SponsoredCampaignRow campaign,
    _SponsoredCampaignReportSummary reportSummary,
    List<_SponsoredReportRow> reports,
  ) {
    final t = widget.t;
    final theme = Theme.of(context);
    final latestReason = reportSummary.latestReason.trim();
    final latestDetails = reportSummary.latestDetails.trim();
    final latestPlacement = reportSummary.latestPlacement.trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  t('adminSponsoredAdsReportsTitle'),
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final useFullRow = constraints.maxWidth >= 400;
              final itemWidth = useFullRow
                  ? (constraints.maxWidth - 24) / 3
                  : (constraints.maxWidth - 12) / 2;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _buildInlineMetricStat(
                    label: t('adminSponsoredAdsReportSummaryTimes'),
                    value: reportSummary.reportCount.toString(),
                    icon: Icons.flag_outlined,
                    width: itemWidth,
                    onTap: () => _showReportTimesDialog(campaign, reports),
                  ),
                  _buildInlineMetricStat(
                    label: t('adminSponsoredAdsReportSummaryUsers'),
                    value: reportSummary.uniqueReporterCount.toString(),
                    icon: Icons.people_outline,
                    width: itemWidth,
                    onTap: () => _showReportUsersDialog(campaign, reports),
                  ),
                  _buildInlineMetricStat(
                    label: t('adminSponsoredAdsReportSummaryLastReported'),
                    value: _formatDateTimeValue(
                      reportSummary.lastReportedAt,
                      includeTime: true,
                    ),
                    icon: Icons.schedule_outlined,
                    width: itemWidth,
                    onTap: () => _showLastReportDialog(campaign, reports),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Text(
            '${t('adminSponsoredAdsReportSummaryLatestReason')}: '
            '${latestReason.isEmpty ? '-' : _reportReasonLabel(latestReason)}',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${t('adminSponsoredAdsReportSummaryLatestPlacement')}: '
            '${latestPlacement.isEmpty ? '-' : _placementLabel(latestPlacement)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (latestDetails.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(latestDetails, style: theme.textTheme.bodyMedium),
          ],
          if (reports.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              t('adminSponsoredAdsReportsTitle'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            ...reports
                .take(3)
                .map((report) => _buildReportListItem(theme, t, report)),
          ],
        ],
      ),
    );
  }

  Widget _buildInlineMetricStat({
    required String label,
    required String value,
    required IconData icon,
    VoidCallback? onTap,
    double? width,
  }) {
    final theme = Theme.of(context);
    final content = Container(
      width: width,
      constraints: width == null
          ? const BoxConstraints(minWidth: 180, maxWidth: 220)
          : null,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (onTap == null) {
      return content;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: content,
      ),
    );
  }

  Widget _buildControlsDisabledState({
    required bool enabled,
    required Widget child,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: IgnorePointer(ignoring: !enabled, child: child),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
    bool enabled = true,
    ValueChanged<String>? onChanged,
    TextAlign textAlign = TextAlign.left,
    TextDirection? textDirection,
    String? helperText,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      onChanged: onChanged,
      textAlign: textAlign,
      textDirection: textDirection,
      minLines: maxLines,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _buildDropdownField({
    required String label,
    required String value,
    required Map<String, String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      key: ValueKey('$label::$value'),
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: items.entries
          .map(
            (entry) => DropdownMenuItem<String>(
              value: entry.key,
              child: Text(entry.value),
            ),
          )
          .toList(growable: false),
      onChanged: onChanged,
    );
  }

  Widget _buildAnalyticsSummary(
    BuildContext context,
    _SponsoredDashboardData data,
  ) {
    final t = widget.t;
    final totals = data.totalMetrics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t('adminSponsoredAdsAnalyticsTitle'),
          style: Theme.of(context).textTheme.titleMedium,
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
                  totals.impressions.toString(),
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
                  totals.clicks.toString(),
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
                  t('adminSponsoredAdsMetricReports'),
                  totals.reports.toString(),
                  Icons.flag_outlined,
                  width: itemWidth,
                  subtitle: data.lastReportAt == null
                      ? null
                      : t(
                          'adminSponsoredAdsMetricLastEventTime',
                          params: {
                            'time': _formatEventDateTime(data.lastReportAt!),
                          },
                        ),
                ),
                _buildMetricCard(
                  context,
                  t('adminSponsoredAdsMetricCtr'),
                  '${totals.ctrPercent.toStringAsFixed(2)}%',
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
              segments: [
                ButtonSegment(value: '7d', label: Text(t('adminAdsRange7d'))),
                ButtonSegment(value: '30d', label: Text(t('adminAdsRange30d'))),
                ButtonSegment(value: '90d', label: Text(t('adminAdsRange90d'))),
                ButtonSegment(value: 'all', label: Text(t('adminAdsRangeAll'))),
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
                  '${_formatShortDateTime(_customStart!.toLocal())}  →  '
                  '${_formatShortDateTime(_customEnd!.toLocal())}',
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
    final start = await _pickDateTime(_customStart ?? DateTime.now());
    if (start == null || !mounted) return;
    final end = await _pickDateTime(_customEnd ?? start);
    if (end == null || !mounted) return;
    setState(() {
      _rangePreset = 'custom';
      // _pickDateTime returns UTC; keep local-day semantics for the window.
      _customStart = start.toLocal();
      _customEnd = end.toLocal();
    });
    _scheduleDashboardReload(
      clearCache: false,
    ); // Smart cache will handle reuse
  }

  /// Short local date+time for the custom-range chip.
  String _formatShortDateTime(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}/${two(dt.month)}/${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
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

  Widget _buildToggleTile({
    required String label,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SwitchListTile.adaptive(
        value: value,
        onChanged: onChanged,
        title: Text(label),
        subtitle: subtitle != null ? Text(subtitle) : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
    );
  }

  Widget _buildDateButton({
    required String label,
    required DateTime? value,
    required VoidCallback onTap,
    VoidCallback? onClear,
  }) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.schedule_outlined),
      label: Text(value == null ? label : '$label: ${_formatDateTime(value)}'),
      onLongPress: onClear,
    );
  }

  Widget _buildFilterChip({
    required String label,
    required _SponsoredCampaignFilter filter,
  }) {
    return FilterChip(
      label: Text(label),
      selected: _filter == filter,
      onSelected: (_) {
        setState(() => _filter = filter);
      },
    );
  }

  Widget _buildStatusBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildEnabledBadge(bool enabled) {
    final t = widget.t;
    final backgroundColor = enabled ? Colors.green.shade50 : Colors.red.shade50;
    final foregroundColor = enabled
        ? Colors.green.shade700
        : Colors.red.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foregroundColor.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            enabled ? Icons.check_circle : Icons.pause_circle,
            size: 14,
            color: foregroundColor,
          ),
          const SizedBox(width: 6),
          Text(
            enabled ? t('generalEnabled') : t('generalDisabled'),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: foregroundColor,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCampaignImagePreview(_SponsoredCampaignRow campaign) async {
    final imageUrl = campaign.imageUrl.trim();
    if (imageUrl.isEmpty) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          campaign.headlinePreview.isEmpty
                              ? campaign.internalName
                              : campaign.headlinePreview,
                          style: Theme.of(dialogContext).textTheme.titleMedium,
                          textDirection: _textDirectionFor(
                            campaign.headlinePreview.isEmpty
                                ? campaign.internalName
                                : campaign.headlinePreview,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close),
                        tooltip: widget.t('generalClose'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CachedNetworkImage(
                        imageUrl: imageUrl,
                        fit: BoxFit.contain,
                        width: double.infinity,
                        errorWidget: (context, error, stackTrace) => SizedBox(
                          height: 240,
                          child: Center(
                            child: Text(
                              widget.t('adminSponsoredAdsImagePreviewFailed'),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showCampaignEventDetails(
    _SponsoredCampaignRow campaign, {
    required String eventType,
    required String title,
    int totalCount = 0,
  }) async {
    final t = widget.t;
    final countLabel = eventType == 'click'
        ? t('adminSponsoredAdsMetricClicks')
        : t('adminSponsoredAdsMetricImpressions');
    final future = _loadEventDetailsForCampaign(campaign.campaignId, eventType);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 760),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: theme.textTheme.titleLarge),
                            const SizedBox(height: 6),
                            Text(
                              campaign.headlinePreview.isEmpty
                                  ? campaign.internalName
                                  : campaign.headlinePreview,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              textDirection: _textDirectionFor(
                                campaign.headlinePreview.isEmpty
                                    ? campaign.internalName
                                    : campaign.headlinePreview,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close),
                        tooltip: t('generalClose'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: FutureBuilder<List<_SponsoredCampaignEventRow>>(
                      future: future,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }

                        if (snapshot.hasError) {
                          return Center(
                            child: Text(t('adminDrilldownLoadFailed')),
                          );
                        }

                        final events =
                            snapshot.data ??
                            const <_SponsoredCampaignEventRow>[];
                        if (events.isEmpty) {
                          return Center(
                            child: Text(t('adminSponsoredAdsEventNoData')),
                          );
                        }

                        final userSummaries = _summarizeEventsByUser(events);
                        final uniqueUsers = events
                            .map((event) => event.userId)
                            .where((id) => id.trim().isNotEmpty)
                            .toSet()
                            .length;
                        final lastEventAt = events.first.createdAt;
                        final shownCount = events.length;

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                _buildInlineMetricStat(
                                  label: countLabel,
                                  value: totalCount > 0
                                      ? (shownCount < totalCount
                                            ? t(
                                                'adminSponsoredAdsShowingLast',
                                                params: {
                                                  'total': totalCount
                                                      .toString(),
                                                  'count': shownCount
                                                      .toString(),
                                                },
                                              )
                                            : totalCount.toString())
                                      : shownCount.toString(),
                                  icon: eventType == 'click'
                                      ? Icons.ads_click_outlined
                                      : Icons.visibility_outlined,
                                ),
                                _buildInlineMetricStat(
                                  label: t(
                                    'adminSponsoredAdsMetricUniqueUsers',
                                  ),
                                  value: uniqueUsers.toString(),
                                  icon: Icons.people_outline,
                                ),
                                _buildInlineMetricStat(
                                  label: t('adminSponsoredAdsMetricLastEvent'),
                                  value: _formatDateTimeValue(
                                    lastEventAt,
                                    includeTime: true,
                                  ),
                                  icon: Icons.schedule_outlined,
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              child: ListView.separated(
                                itemCount: userSummaries.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final summary = userSummaries[index];
                                  return _buildEventSummaryListItem(
                                    theme,
                                    t,
                                    summary,
                                    countLabel,
                                  );
                                },
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showCampaignReportsOverview(
    _SponsoredCampaignRow campaign,
    _SponsoredCampaignReportSummary? reportSummary,
  ) async {
    final t = widget.t;
    final future = _loadReportDetailsForCampaign(campaign.campaignId);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 760),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              campaign.headlinePreview.isEmpty
                                  ? t('adminSponsoredAdsReportsDialogTitle')
                                  : campaign.headlinePreview,
                              style: theme.textTheme.titleLarge,
                              textDirection: campaign.headlinePreview.isEmpty
                                  ? null
                                  : _textDirectionFor(campaign.headlinePreview),
                            ),
                            const SizedBox(height: 6),
                            if (reportSummary != null)
                              Text(
                                t(
                                  'adminSponsoredAdsReportDialogSubtitle',
                                  params: {
                                    'count': reportSummary.reportCount
                                        .toString(),
                                    'users': reportSummary.uniqueReporterCount
                                        .toString(),
                                  },
                                ),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close),
                        tooltip: t('generalClose'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: FutureBuilder<List<_SponsoredReportRow>>(
                      future: future,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }

                        if (snapshot.hasError) {
                          return Center(
                            child: Text(t('adminDrilldownLoadFailed')),
                          );
                        }

                        final reports =
                            snapshot.data ?? const <_SponsoredReportRow>[];
                        if (reports.isEmpty) {
                          return Center(
                            child: Text(t('adminSponsoredAdsReportsEmpty')),
                          );
                        }

                        final effectiveSummary =
                            reportSummary ??
                            _SponsoredCampaignReportSummary.fromReports(
                              campaign.campaignId,
                              reports,
                            );

                        return ListView(
                          children: [
                            _buildReportOverviewSection(
                              campaign,
                              effectiveSummary,
                              reports,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showReportTimesDialog(
    _SponsoredCampaignRow campaign,
    List<_SponsoredReportRow> reports,
  ) async {
    await _showSimpleListDialog(
      title: widget.t('adminSponsoredAdsReportsTitle'),
      subtitle: campaign.headlinePreview.isEmpty
          ? campaign.internalName
          : campaign.headlinePreview,
      items: reports
          .map((report) {
            return _buildReportListItem(Theme.of(context), widget.t, report);
          })
          .toList(growable: false),
    );
  }

  Future<void> _showReportUsersDialog(
    _SponsoredCampaignRow campaign,
    List<_SponsoredReportRow> reports,
  ) async {
    final t = widget.t;
    final grouped = <String, List<_SponsoredReportRow>>{};
    for (final report in reports) {
      final key = report.reporterUserId.trim().isEmpty
          ? report.reporterName.trim()
          : report.reporterUserId.trim();
      grouped.putIfAbsent(key, () => <_SponsoredReportRow>[]).add(report);
    }

    final entries = grouped.values.toList(growable: false)
      ..sort((a, b) {
        final aLatest =
            a.first.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bLatest =
            b.first.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bLatest.compareTo(aLatest);
      });

    await _showSimpleListDialog(
      title: t('adminSponsoredAdsReportUsersDialogTitle'),
      subtitle: campaign.headlinePreview.isEmpty
          ? campaign.internalName
          : campaign.headlinePreview,
      items: entries
          .map((userReports) {
            final first = userReports.first;
            final reporterName = first.reporterName.trim().isEmpty
                ? t('adminSponsoredAdsReportReporterFallback')
                : first.reporterName.trim();
            return Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    reporterName,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${t('adminSponsoredAdsReportSummaryTimes')}: ${userReports.length}',
                  ),
                  const SizedBox(height: 4),
                  Text('${t('adminDrilldownUserId')}: ${first.reporterUserId}'),
                  const SizedBox(height: 4),
                  Text(
                    '${t('adminSponsoredAdsReportSummaryLastReported')}: '
                    '${_formatDateTimeValue(first.createdAt, includeTime: true)}',
                  ),
                ],
              ),
            );
          })
          .toList(growable: false),
    );
  }

  Future<void> _showLastReportDialog(
    _SponsoredCampaignRow campaign,
    List<_SponsoredReportRow> reports,
  ) async {
    final t = widget.t;
    if (reports.isEmpty) {
      return;
    }

    await _showSimpleListDialog(
      title: t('adminSponsoredAdsReportLastDialogTitle'),
      subtitle: campaign.headlinePreview.isEmpty
          ? campaign.internalName
          : campaign.headlinePreview,
      items: [_buildReportListItem(Theme.of(context), t, reports.first)],
    );
  }

  Future<void> _showSimpleListDialog({
    required String title,
    required String subtitle,
    required List<Widget> items,
  }) async {
    final t = widget.t;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 760),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: theme.textTheme.titleLarge),
                            const SizedBox(height: 6),
                            Text(
                              subtitle,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              textDirection: _textDirectionFor(subtitle),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close),
                        tooltip: t('generalClose'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: items.isEmpty
                        ? Center(child: Text(t('adminSponsoredAdsEventNoData')))
                        : ListView.separated(
                            itemCount: items.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) => items[index],
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<_SponsoredCampaignEventUserSummary> _summarizeEventsByUser(
    List<_SponsoredCampaignEventRow> events,
  ) {
    final grouped = <String, List<_SponsoredCampaignEventRow>>{};
    for (final event in events) {
      final key = event.userId.trim().isEmpty
          ? event.userName.trim()
          : event.userId.trim();
      grouped.putIfAbsent(key, () => <_SponsoredCampaignEventRow>[]).add(event);
    }

    final summaries =
        grouped.values
            .map((items) {
              final sorted = [...items]
                ..sort((a, b) {
                  final aTime =
                      a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
                  final bTime =
                      b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
                  return bTime.compareTo(aTime);
                });
              return _SponsoredCampaignEventUserSummary.fromEvents(sorted);
            })
            .toList(growable: false)
          ..sort((a, b) {
            final byCount = b.eventCount.compareTo(a.eventCount);
            if (byCount != 0) {
              return byCount;
            }
            final aTime =
                a.lastEventAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            final bTime =
                b.lastEventAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            return bTime.compareTo(aTime);
          });

    return summaries;
  }

  Widget _buildEventSummaryListItem(
    ThemeData theme,
    AdminTextLookup t,
    _SponsoredCampaignEventUserSummary summary,
    String countLabel,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            summary.userName.trim().isEmpty
                ? t('adminSponsoredAdsReportReporterFallback')
                : summary.userName.trim(),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${t('adminDrilldownUserId')}: ${summary.userId}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text('$countLabel: ${summary.eventCount}'),
          const SizedBox(height: 4),
          Text(
            '${t('adminSponsoredAdsMetricLastEvent')}: '
            '${_formatDateTimeValue(summary.lastEventAt, includeTime: true)}',
          ),
          const SizedBox(height: 4),
          Text(
            '${t('adminSponsoredAdsEventPlacement')}: '
            '${summary.placements.map(_placementLabel).join(', ')}',
          ),
          if (summary.platforms.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${t('adminSponsoredAdsEventPlatform')}: '
              '${summary.platforms.map(_platformLabel).join(', ')}',
            ),
          ],
          if (summary.locales.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${t('adminSponsoredAdsEventLocale')}: '
              '${summary.locales.join(', ')}',
            ),
          ],
          if (summary.destinationUrls.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${t('adminSponsoredAdsEventDestinationUrl')}: '
              '${summary.destinationUrls.join(', ')}',
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReportListItem(
    ThemeData theme,
    AdminTextLookup t,
    _SponsoredReportRow report,
  ) {
    final reporterName = report.reporterName.trim().isEmpty
        ? t('adminSponsoredAdsReportReporterFallback')
        : report.reporterName.trim();
    final details = report.details.trim().isEmpty
        ? t('adminSponsoredAdsReportDetailsFallback')
        : report.details.trim();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _reportReasonLabel(report.reason),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$reporterName · ${_formatDateTimeValue(report.createdAt, includeTime: true)}',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${t('adminDrilldownUserId')}: ${report.reporterUserId}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _placementLabel(report.placement),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(details, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  String _reportReasonLabel(String reason) {
    final t = widget.t;
    switch (reason.trim()) {
      case 'user_reported':
        return t('adminSponsoredAdsReportReasonUserReported');
      default:
        return t('adminSponsoredAdsReportReasonUserReported');
    }
  }

  List<_SponsoredCampaignRow> _applyFilters(List<_SponsoredCampaignRow> rows) {
    final query = _searchController.text.trim().toLowerCase();

    return rows
        .where((row) {
          final matchesFilter = switch (_filter) {
            _SponsoredCampaignFilter.all => true,
            _SponsoredCampaignFilter.approved =>
              row.moderationStatus == 'approved',
            _SponsoredCampaignFilter.draft => row.moderationStatus == 'draft',
            _SponsoredCampaignFilter.rejected =>
              row.moderationStatus == 'rejected',
            // 'paused' is a moderation state; 'disabled' is the is_active flag.
            // They were previously conflated, so a paused-but-active campaign
            // and an approved-but-inactive campaign both showed under "Paused".
            _SponsoredCampaignFilter.paused => row.moderationStatus == 'paused',
            _SponsoredCampaignFilter.disabled => !row.isActive,
          };

          if (!matchesFilter) {
            return false;
          }

          if (query.isEmpty) {
            return true;
          }

          return [
            row.internalName,
            row.advertiserName,
            row.destinationUrl,
            row.headlinePreview,
            row.bodyPreview,
            row.placement,
            row.platform,
            ...row.placements,
            ...row.platforms,
            ...row.targetTiers,
          ].any((value) => value.toLowerCase().contains(query));
        })
        .toList(growable: false);
  }

  Future<void> _refresh() async {
    if (!mounted) {
      return;
    }
    _invalidateDashboardCaches();
    setState(() {
      _configHydrated = false;
      _cachedConfig = null; // Clear cached config to prevent stale data
      _adConfigFuture = _loadAdConfig().then((data) {
        if (mounted) {
          setState(() {
            _cachedConfig = data;
            _hydrateConfig(data, fromServer: true);
          });
        }
        return data;
      });
      _dashboardFuture = _loadDashboardData().then((data) {
        if (mounted) {
          setState(() => _cachedDashboard = data);
        }
        return data;
      });
    });
  }

  void _hydrateConfig(
    _SponsoredAdConfigState config, {
    bool fromServer = false,
  }) {
    if (_hasLocalConfigEdits && !_isSavingConfig) {
      return;
    }
    _isHydratingConfig = true;
    _configHydrated = true;
    if (fromServer) _serverConfigHydrated = true;
    _adsEnabled = config.adsEnabled;
    _sponsoredCardsEnabled = config.sponsoredCardsEnabled;
    _familySafeOnly = config.familySafeOnly;
    _reportEnabled = config.reportEnabled;
    _maxImpressionsController.text = config.maxImpressionsPerSession.toString();
    _minMinutesController.text = config.minMinutesBetweenImpressions.toString();
    _firstDelaySecondsController.text = config.firstImpressionDelaySeconds
        .toString();
    // Update master controls
    _masterAllowedPlacements
      ..clear()
      ..addAll(config.allowedPlacements);
    _masterAllowedPlatforms
      ..clear()
      ..addAll(config.allowedPlatforms);
    _masterAllowedTiers
      ..clear()
      ..addAll(config.allowedTiers);
    if (_isEditorAtPristineShell()) {
      _selectedPlatforms
        ..clear()
        ..addAll(_masterAllowedPlatforms);
      _selectedTiers
        ..clear()
        ..addAll(_masterAllowedTiers);
    }
    // Capture original values for change detection
    _captureOriginalConfigValues(config);
    _hasLocalConfigEdits = false;
    _isHydratingConfig = false;
  }

  Future<DateTime?> _pickDateTime(DateTime initialDate) async {
    final localInitial = initialDate.toLocal();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: localInitial,
      firstDate: DateTime(2024),
      lastDate: DateTime(2035),
    );
    if (pickedDate == null || !mounted) {
      return null;
    }
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(localInitial),
    );
    if (pickedTime == null) {
      return null;
    }
    return DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    ).toUtc();
  }

  bool get _hasConfigChanges {
    final hasChanges =
        _adsEnabled != _originalAdsEnabled ||
        _sponsoredCardsEnabled != _originalSponsoredCardsEnabled ||
        _familySafeOnly != _originalFamilySafeOnly ||
        _reportEnabled != _originalReportEnabled ||
        _maxImpressionsController.text.trim() !=
            _originalMaxImpressions.toString() ||
        _minMinutesController.text.trim() != _originalMinMinutes.toString() ||
        _firstDelaySecondsController.text.trim() !=
            _originalFirstDelaySeconds.toString() ||
        !_setEquals(_masterAllowedPlacements, _originalAllowedPlacements) ||
        !_setEquals(_masterAllowedPlatforms, _originalAllowedPlatforms) ||
        !_setEquals(_masterAllowedTiers, _originalAllowedTiers);
    return hasChanges;
  }

  bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    return a.every(b.contains);
  }

  void _captureOriginalConfigValues(_SponsoredAdConfigState config) {
    _originalAdsEnabled = config.adsEnabled;
    _originalSponsoredCardsEnabled = config.sponsoredCardsEnabled;
    _originalFamilySafeOnly = config.familySafeOnly;
    _originalReportEnabled = config.reportEnabled;
    _originalMaxImpressions = config.maxImpressionsPerSession;
    _originalMinMinutes = config.minMinutesBetweenImpressions;
    _originalFirstDelaySeconds = config.firstImpressionDelaySeconds;
    _originalAllowedPlacements
      ..clear()
      ..addAll(config.allowedPlacements);
    _originalAllowedPlatforms
      ..clear()
      ..addAll(config.allowedPlatforms);
    _originalAllowedTiers
      ..clear()
      ..addAll(config.allowedTiers);
  }

  String _statusLabel(String value) {
    final t = widget.t;
    return switch (value) {
      'approved' => t('adminSponsoredAdsStatusApproved'),
      'rejected' => t('adminSponsoredAdsStatusRejected'),
      'paused' => t('adminSponsoredAdsStatusPaused'),
      _ => t('adminSponsoredAdsStatusDraft'),
    };
  }

  String _placementLabel(String value) {
    final t = widget.t;
    return switch (value) {
      'home_inline' => t('adminSponsoredAdsPlacementHome'),
      'matches_inline' => t('adminSponsoredAdsPlacementMatches'),
      'chats_inline' => t('adminSponsoredAdsPlacementChats'),
      'events_inline' => t('adminSponsoredAdsPlacementEvents'),
      'profile_inline' => t('adminSponsoredAdsPlacementProfile'),
      _ => value,
    };
  }

  String _platformLabel(String value) {
    final t = widget.t;
    return switch (value) {
      'android' => t('adminSponsoredAdsPlatformAndroid'),
      'ios' => t('adminSponsoredAdsPlatformIos'),
      'web' => t('adminSponsoredAdsPlatformWeb'),
      'windows' => t('adminSponsoredAdsPlatformWindows'),
      'macos' => t('adminSponsoredAdsPlatformMacos'),
      'linux' => t('adminSponsoredAdsPlatformLinux'),
      _ => t('adminSponsoredAdsPlatformAll'),
    };
  }

  String _formatDateTime(DateTime? value) {
    return _formatDateTimeValue(value, includeTime: true);
  }

  String _formatDateTimeValue(DateTime? value, {required bool includeTime}) {
    if (value == null) {
      return '-';
    }
    final local = value.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    if (!includeTime) {
      return '${local.year}-$mm-$dd';
    }
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$mm-$dd $hh:$min';
  }

  String _slugify(String input) {
    final cleaned = input.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '_',
    );
    final compact = cleaned
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return compact.isEmpty ? 'campaign' : compact;
  }

  String _translationKey(String suffix) {
    final slug = _slugify(_internalNameController.text);
    final stablePart =
        _editingCampaignId?.replaceAll('-', '_') ??
        DateTime.now().millisecondsSinceEpoch.toString();
    return 'ads_${slug}_${stablePart}_$suffix';
  }

  Future<_SponsoredDashboardData> _loadDashboardData() async {
    // Campaigns are authoritative server data, never analytics-cached.
    //
    // Previously this method returned `campaigns` straight from the Hive
    // snapshot whenever the analytics cache covered the requested range. For
    // the 7d/30d/90d presets the window is day-aligned, so that cache always
    // matched and ad_campaigns was effectively never re-read: newly saved
    // campaigns rendered as an empty list, enable/disable toggles appeared to
    // do nothing, and other admins' changes were invisible.
    List<_SponsoredCampaignRow> cachedCampaigns = [];
    AdminLocalDbService? localDb;
    try {
      localDb = await AdminLocalDbService.instance;
      final cachedAds = await localDb.loadSponsoredAds();
      cachedCampaigns = _parseCampaignRows(cachedAds);
    } catch (_) {}

    // Load cached metrics for offline fallback
    Map<String, dynamic>? cachedAnalytics;
    try {
      if (localDb != null) {
        cachedAnalytics = await localDb.loadSponsoredAdAnalytics();
      }
    } catch (_) {}
    final cachedMetrics = _parseMetricsFromCache(cachedAnalytics);
    final cachedReportSummaries = _parseReportSummariesFromCache(
      cachedAnalytics,
    );

    // If offline, fall back entirely to the local snapshot.
    if (adminOfflineCacheManager.shouldUseCachedData()) {
      return _SponsoredDashboardData(
        campaigns: cachedCampaigns,
        metricsByCampaign: cachedMetrics,
        recentReports: const [],
        reportSummariesByCampaign: cachedReportSummaries,
      );
    }

    // Always re-read campaigns from the database when online. Only the
    // date-range-scoped aggregates are eligible for the analytics cache.
    //
    // The three reads are independent: a failing analytics RPC must not
    // discard a successful campaign read (and vice versa). A previous version
    // used Future.wait, where the first rejection threw away all three results
    // and fell back to the stale local snapshot.
    List<_SponsoredCampaignRow>? serverCampaigns;
    Map<String, _SponsoredCampaignMetrics>? metrics;
    Map<String, _SponsoredCampaignReportSummary>? reportSummaries;

    try {
      serverCampaigns = await _loadCampaigns();
    } catch (e) {
      debugPrint('[SponsoredAds] Campaign load failed: $e');
    }
    try {
      metrics = await _loadMetricsByCampaign();
    } catch (e) {
      debugPrint('[SponsoredAds] Metrics load failed: $e');
    }
    try {
      reportSummaries = await _loadReportSummariesByCampaign();
    } catch (e) {
      debugPrint('[SponsoredAds] Report summary load failed: $e');
    }

    if (serverCampaigns == null) {
      // Could not read campaigns (offline mid-flight, RLS rejection, ...).
      // Show the local snapshot rather than an empty screen.
      return _SponsoredDashboardData(
        campaigns: cachedCampaigns,
        metricsByCampaign: metrics ?? cachedMetrics,
        recentReports: const [],
        reportSummariesByCampaign: reportSummaries ?? cachedReportSummaries,
      );
    }

    // Persist the fresh campaign snapshot so the offline path stays useful.
    try {
      if (localDb != null) {
        await localDb.saveSponsoredAds(
          serverCampaigns.map((c) => c.toMap()).toList(growable: false),
        );
      }
    } catch (_) {}

    final requestedWindow = _analyticsWindowUtc();
    final cachedEntry = _findCachedAnalyticsCovering(
      requestedWindow.startUtc,
      requestedWindow.endUtc,
    );

    if (metrics == null || reportSummaries == null) {
      // Campaigns loaded but the aggregates did not. Keep the campaigns and
      // fall back to the last known aggregates instead of blanking analytics.
      return _SponsoredDashboardData(
        campaigns: serverCampaigns,
        metricsByCampaign: cachedEntry?.data.metricsByCampaign ?? cachedMetrics,
        recentReports: cachedEntry?.data.recentReports ?? const [],
        reportSummariesByCampaign:
            cachedEntry?.data.reportSummariesByCampaign ??
            cachedReportSummaries,
      );
    }

    if (cachedEntry != null) {
      debugPrint('[SponsoredAds] Reusing cached analytics for range');
      return _SponsoredDashboardData(
        campaigns: serverCampaigns,
        metricsByCampaign: cachedEntry.data.metricsByCampaign,
        recentReports: cachedEntry.data.recentReports,
        reportSummariesByCampaign: cachedEntry.data.reportSummariesByCampaign,
      );
    }

    // Save metrics and report summaries to local storage for offline use
    try {
      if (localDb != null) {
        await localDb.saveSponsoredAdAnalytics({
          'metrics': metrics.values.map((m) => m.toMap()).toList(),
          'reportSummaries': reportSummaries.values
              .map((s) => s.toMap())
              .toList(),
          'cachedAt': DateTime.now().toIso8601String(),
        });
      }
    } catch (_) {}

    final dashboardData = _SponsoredDashboardData(
      campaigns: serverCampaigns,
      metricsByCampaign: metrics,
      recentReports: const [],
      reportSummariesByCampaign: reportSummaries,
    );

    _cacheAnalyticsData(
      dashboardData,
      requestedWindow.startUtc,
      requestedWindow.endUtc,
    );

    return dashboardData;
  }

  /// Drop every cached analytics range so the next load re-reads the database.
  /// Called after any local mutation and on manual refresh.
  ///
  /// `_cachedDashboard` is intentionally left in place: the UI renders it
  /// immediately (avoiding a spinner flash) and the in-flight reload replaces
  /// it with fresh server data.
  void _invalidateDashboardCaches() {
    _analyticsCache.clear();
    _scheduleAnalyticsCachePersist();
  }

  List<_SponsoredCampaignRow> _parseCampaignRows(
    List<Map<String, dynamic>> rows,
  ) {
    return rows.map((row) {
      final creativesRaw = row['ad_creatives'];
      final creatives = creativesRaw is List
          ? creativesRaw
                .map((c) => Map<String, dynamic>.from(c as Map))
                .toList()
          : <Map<String, dynamic>>[];
      final placements = _orderedDistinctPlacements(
        creatives
            .map((c) => c['placement']?.toString())
            .whereType<String>()
            .where((value) => value.isNotEmpty),
      );
      final platforms = _orderedDistinctPlatforms(
        creatives
            .map((c) => c['platform']?.toString())
            .whereType<String>()
            .where((value) => value.isNotEmpty),
      );

      final primaryCreative = creatives.isNotEmpty
          ? creatives.first
          : <String, dynamic>{};
      final creativeId = primaryCreative['id']?.toString() ?? '';
      final placement =
          primaryCreative['placement']?.toString() ??
          row['placement']?.toString() ??
          '';

      // Build creativeIdsByPlacement map (placement -> platform -> creativeId)
      final creativeIdsByPlacement = <String, Map<String, String>>{};
      for (final creative in creatives) {
        final p = creative['placement']?.toString();
        final platform = creative['platform']?.toString() ?? 'all';
        final id = creative['id']?.toString();
        if (p != null && p.isNotEmpty && id != null && id.isNotEmpty) {
          creativeIdsByPlacement.putIfAbsent(p, () => {});
          creativeIdsByPlacement[p]![platform] = id;
        }
      }

      return _SponsoredCampaignRow(
        campaignId: row['id']?.toString() ?? '',
        creativeId: creativeId,
        internalName: row['internal_name']?.toString() ?? '',
        advertiserName: row['advertiser_name']?.toString() ?? '',
        destinationUrl: row['destination_url']?.toString() ?? '',
        headlineKey: primaryCreative['headline_key']?.toString() ?? '',
        headlinePreview: row['headline_preview']?.toString() ?? '',
        bodyKey: primaryCreative['body_key']?.toString() ?? '',
        bodyPreview: row['body_preview']?.toString() ?? '',
        ctaKey: primaryCreative['cta_key']?.toString() ?? '',
        sponsorNameKey: primaryCreative['sponsor_name_key']?.toString() ?? '',
        imageUrl: primaryCreative['image_url']?.toString() ?? '',
        placement: placement,
        placements: placements,
        creativeIdsByPlacement: creativeIdsByPlacement,
        platform:
            primaryCreative['platform']?.toString() ??
            row['platform']?.toString() ??
            'all',
        platforms: platforms,
        targetTiers:
            (row['target_tiers'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const ['free'],
        dailyImpressionCap: (row['daily_impression_cap'] as num?)?.toInt(),
        totalImpressionCap: (row['total_impression_cap'] as num?)?.toInt(),
        moderationStatus: row['moderation_status']?.toString() ?? 'draft',
        familySafe: row['family_safe'] as bool? ?? true,
        isActive: row['is_active'] as bool? ?? true,
        creativeIsActive: primaryCreative['is_active'] as bool? ?? true,
        sortPriority:
            (primaryCreative['sort_priority'] as num?)?.toInt() ??
            (row['sort_priority'] as num?)?.toInt() ??
            100,
        startsAt: row['starts_at'] != null
            ? DateTime.tryParse(row['starts_at'].toString())
            : null,
        endsAt: row['ends_at'] != null
            ? DateTime.tryParse(row['ends_at'].toString())
            : null,
      );
    }).toList();
  }

  Future<List<_SponsoredLocaleOption>> _loadLocaleOptions() async {
    try {
      final response = await publicReferenceDataService
          .fetchSupportedLanguages();
      final rows = List<Map<String, dynamic>>.from(response);
      final options = rows
          .map(
            (row) => _SponsoredLocaleOption(
              code: (row['language_code'] ?? '')
                  .toString()
                  .trim()
                  .toLowerCase(),
              displayName: (row['display_name'] ?? '').toString().trim(),
            ),
          )
          .where((option) => option.code.isNotEmpty)
          .toList(growable: false);
      final merged = <String, _SponsoredLocaleOption>{
        for (final option in _defaultLocaleOptions) option.code: option,
        for (final option in options)
          option.code: option.displayName.isEmpty
              ? _SponsoredLocaleOption(
                  code: option.code,
                  displayName: _localeDisplayName(option.code),
                )
              : option,
      };
      final list = merged.values.toList(growable: false)
        ..sort((a, b) {
          if (a.code == 'en') return -1;
          if (b.code == 'en') return 1;
          return a.displayName.compareTo(b.displayName);
        });
      if (mounted) {
        setState(() {
          _availableLocaleOptions = list;
        });
      } else {
        _availableLocaleOptions = list;
      }
      return list;
    } catch (_) {
      final fallback = _defaultLocaleOptions;
      _availableLocaleOptions = fallback;
      return fallback;
    }
  }

  Future<List<_SponsoredCampaignRow>> _loadCampaigns() async {
    final locale = widget.localeCode.trim().isEmpty
        ? 'en'
        : widget.localeCode.trim();
    final response = await Supabase.instance.client
        .from('ad_campaigns')
        .select(
          'id, internal_name, advertiser_name, destination_url, moderation_status, family_safe, is_active, starts_at, ends_at, sort_priority, daily_impression_cap, total_impression_cap, updated_at, target_tiers, '
          'ad_creatives(id, placement, platform, headline_key, body_key, cta_key, sponsor_name_key, image_url, is_active, sort_priority)',
        )
        .order('updated_at', ascending: false)
        .timeout(const Duration(seconds: 15));

    final rows = List<Map<String, dynamic>>.from(response);
    final translationKeys = <String>{};
    for (final row in rows) {
      final creativesRaw = row['ad_creatives'];
      if (creativesRaw is List && creativesRaw.isNotEmpty) {
        final creative = Map<String, dynamic>.from(creativesRaw.first as Map);
        for (final key in [
          creative['headline_key'],
          creative['body_key'],
          creative['cta_key'],
          creative['sponsor_name_key'],
        ]) {
          final value = (key ?? '').toString().trim();
          if (value.isNotEmpty) {
            translationKeys.add(value);
          }
        }
      }
    }

    final translationMap = <String, String>{};
    if (translationKeys.isNotEmpty) {
      final localeTranslations = await publicReferenceDataService
          .fetchTranslations(locale);
      final fallbackTranslations = locale == 'en'
          ? const <String, String>{}
          : await publicReferenceDataService.fetchTranslations('en');
      for (final key in translationKeys) {
        final localized = localeTranslations[key];
        if (localized != null && localized.isNotEmpty) {
          translationMap['${locale.toLowerCase()}::$key'] = localized;
        }
        final fallback = fallbackTranslations[key];
        if (fallback != null && fallback.isNotEmpty) {
          translationMap['en::$key'] = fallback;
        }
      }
    }

    return rows
        .map((row) {
          final creativesRaw = row['ad_creatives'];
          final creatives = creativesRaw is List
              ? creativesRaw
                    .map((c) => Map<String, dynamic>.from(c as Map))
                    .toList()
              : <Map<String, dynamic>>[];

          // Get the first creative as primary (for backward compatibility)
          final primaryCreative = creatives.isNotEmpty
              ? creatives.first
              : <String, dynamic>{};

          // Collect all unique placements and their creative IDs (by platform)
          final placementValues = <String>[];
          final creativeIdsByPlacement = <String, Map<String, String>>{};
          for (final creative in creatives) {
            final placement = (creative['placement'] ?? '').toString();
            final platform = (creative['platform'] ?? 'all').toString();
            final creativeId = (creative['id'] ?? '').toString();
            if (placement.isNotEmpty && !placementValues.contains(placement)) {
              placementValues.add(placement);
            }
            if (placement.isNotEmpty && creativeId.isNotEmpty) {
              creativeIdsByPlacement.putIfAbsent(placement, () => {});
              creativeIdsByPlacement[placement]![platform] = creativeId;
            }
          }
          final placements = _orderedDistinctPlacements(
            placementValues,
          ).toList(growable: true);
          final platforms = _orderedDistinctPlatforms(
            creatives
                .map((c) => c['platform']?.toString())
                .whereType<String>()
                .where((value) => value.isNotEmpty),
          );

          // Ensure at least one placement exists
          if (placements.isEmpty) {
            placements.add('home_inline');
          }

          String lookup(String key) {
            if (key.trim().isEmpty) {
              return '';
            }
            return translationMap['${locale.toLowerCase()}::$key'] ??
                translationMap['en::$key'] ??
                '';
          }

          final headlineKey = (primaryCreative['headline_key'] ?? '')
              .toString();
          final bodyKey = (primaryCreative['body_key'] ?? '').toString();

          return _SponsoredCampaignRow(
            campaignId: (row['id'] ?? '').toString(),
            creativeId: (primaryCreative['id'] ?? '').toString(),
            internalName: (row['internal_name'] ?? '').toString(),
            advertiserName: (row['advertiser_name'] ?? '').toString(),
            destinationUrl: (row['destination_url'] ?? '').toString(),
            moderationStatus: (row['moderation_status'] ?? 'draft').toString(),
            familySafe: row['family_safe'] == true,
            isActive: row['is_active'] == true,
            startsAt: DateTime.tryParse(
              (row['starts_at'] ?? '').toString(),
            )?.toUtc(),
            endsAt: DateTime.tryParse(
              (row['ends_at'] ?? '').toString(),
            )?.toUtc(),
            sortPriority: (row['sort_priority'] as num?)?.toInt() ?? 100,
            placement: (primaryCreative['placement'] ?? 'home_inline')
                .toString(),
            placements: placements,
            creativeIdsByPlacement: creativeIdsByPlacement,
            platform: (primaryCreative['platform'] ?? 'all').toString(),
            platforms: platforms,
            targetTiers:
                (row['target_tiers'] as List<dynamic>?)
                    ?.map((e) => e.toString())
                    .toList() ??
                const ['free'],
            dailyImpressionCap: (row['daily_impression_cap'] as num?)?.toInt(),
            totalImpressionCap: (row['total_impression_cap'] as num?)?.toInt(),
            imageUrl: (primaryCreative['image_url'] ?? '').toString(),
            creativeIsActive: primaryCreative['is_active'] == true,
            headlineKey: headlineKey,
            bodyKey: bodyKey,
            ctaKey: (primaryCreative['cta_key'] ?? '').toString(),
            sponsorNameKey: (primaryCreative['sponsor_name_key'] ?? '')
                .toString(),
            headlinePreview: lookup(headlineKey),
            bodyPreview: lookup(bodyKey),
          );
        })
        .toList(growable: false);
  }

  /// Find cached analytics data that EXACTLY matches the requested date range.
  /// Returns null if no matching cached data exists.
  ({_SponsoredDashboardData data, DateTime startUtc, DateTime endUtc})?
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
        debugPrint(
          '[SponsoredAds] Found exact cached data for requested range (tolerance: ${endTolerance}s)',
        );
        return entry;
      }
    }
    return null;
  }

  /// Cache analytics data with its date range for exact reuse.
  void _cacheAnalyticsData(
    _SponsoredDashboardData data,
    DateTime startUtc,
    DateTime endUtc,
  ) {
    // Generate cache key based on the range
    final cacheKey = _generateCacheKey(startUtc, endUtc);

    // Store in cache
    _analyticsCache[cacheKey] = (
      data: data,
      startUtc: startUtc,
      endUtc: endUtc,
    );

    debugPrint(
      '[SponsoredAds] Cached analytics data with key: $cacheKey (${_analyticsCache.length} entries)',
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
    for (final entry in persistedCache.entries) {
      try {
        final data = entry.value;
        // Parse metrics and summaries from persisted format
        final metricsMap =
            (data['metrics'] as Map?)?.map(
              (key, value) => MapEntry(
                key.toString(),
                _SponsoredCampaignMetrics.fromMap(value),
              ),
            ) ??
            {};
        final summariesMap =
            (data['reportSummaries'] as Map?)?.map(
              (key, value) => MapEntry(
                key.toString(),
                _SponsoredCampaignReportSummary.fromMap(value),
              ),
            ) ??
            {};

        // Use empty campaigns list since we don't persist full campaign data here
        // (campaigns are cached separately via saveSponsoredAds)
        final dashboardData = _SponsoredDashboardData(
          campaigns: const [],
          metricsByCampaign: metricsMap,
          recentReports: const [],
          reportSummariesByCampaign: summariesMap,
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
          '[SponsoredAds] Failed to restore cache entry ${entry.key}: $e',
        );
      }
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
          // Don't persist campaigns (too large), just metrics
          'metrics': entry.value.data.metricsByCampaign.map(
            (key, value) => MapEntry(key, value.toMap()),
          ),
          'reportSummaries': entry.value.data.reportSummariesByCampaign.map(
            (key, value) => MapEntry(key, value.toMap()),
          ),
        };
      }

      await localDb.saveSponsoredAdAnalyticsCache(persistedCache);
      debugPrint(
        '[SponsoredAds] Persisted ${persistedCache.length} cached date ranges to storage',
      );
    } catch (e) {
      debugPrint('[SponsoredAds] Failed to persist analytics cache: $e');
    }
  }

  Future<Map<String, _SponsoredCampaignMetrics>>
  _loadMetricsByCampaign() async {
    final window = _analyticsWindowUtc();
    final response = await Supabase.instance.client
        .rpc(
          'admin_list_sponsored_campaign_metrics',
          params: {
            'p_start_date': window.startUtc.toIso8601String(),
            'p_end_date': window.endUtc.toIso8601String(),
          },
        )
        .timeout(const Duration(seconds: 15));
    final rows = response is List
        ? List<Map<String, dynamic>>.from(response)
        : const [];
    final map = <String, _SponsoredCampaignMetrics>{};
    for (final row in rows) {
      final item = _SponsoredCampaignMetrics.fromMap(row);
      map[item.campaignId] = item;
    }
    return map;
  }

  Future<Map<String, _SponsoredCampaignReportSummary>>
  _loadReportSummariesByCampaign() async {
    final window = _analyticsWindowUtc();
    final response = await Supabase.instance.client
        .rpc(
          'admin_list_sponsored_campaign_report_summaries',
          params: {
            'p_start_date': window.startUtc.toIso8601String(),
            'p_end_date': window.endUtc.toIso8601String(),
          },
        )
        .timeout(const Duration(seconds: 15));
    final rows = response is List
        ? List<Map<String, dynamic>>.from(response)
        : <Map<String, dynamic>>[];
    final map = <String, _SponsoredCampaignReportSummary>{};
    for (final row in rows) {
      final item = _SponsoredCampaignReportSummary.fromMap(row);
      map[item.campaignId] = item;
    }
    return map;
  }

  Future<List<_SponsoredCampaignEventRow>> _loadEventDetailsForCampaign(
    String campaignId,
    String eventType,
  ) async {
    final response = await Supabase.instance.client.rpc(
      'admin_list_sponsored_campaign_event_details',
      params: {
        'p_campaign_id': campaignId,
        'p_event_type': eventType,
        'p_limit': 200,
      },
    );
    final rawRows = response is List
        ? List<Map<String, dynamic>>.from(response)
        : <Map<String, dynamic>>[];
    // Save to local storage for offline fallback
    try {
      final localDb = await AdminLocalDbService.instance;
      await localDb.saveSectionData(
        'sponsored_events:$campaignId:$eventType',
        rawRows,
      );
    } catch (_) {}
    return rawRows
        .map((row) => _SponsoredCampaignEventRow.fromMap(row))
        .toList(growable: false);
  }

  Future<List<_SponsoredReportRow>> _loadReportDetailsForCampaign(
    String campaignId,
  ) async {
    final response = await Supabase.instance.client.rpc(
      'admin_list_sponsored_campaign_report_details',
      params: {'p_campaign_id': campaignId, 'p_limit': 200},
    );
    final rawRows = response is List
        ? List<Map<String, dynamic>>.from(response)
        : <Map<String, dynamic>>[];
    // Save to local storage for offline fallback
    try {
      final localDb = await AdminLocalDbService.instance;
      await localDb.saveSectionData('sponsored_reports:$campaignId', rawRows);
    } catch (_) {}
    return rawRows
        .map((row) => _SponsoredReportRow.fromMap(row))
        .toList(growable: false);
  }

  Future<_SponsoredAdConfigState> _loadAdConfig() async {
    const keys = [
      'ads.internal.enabled',
      'ads.internal.sponsored_cards_enabled',
      'ads.internal.family_safe_only',
      'ads.internal.report_enabled',
      'ads.internal.max_impressions_per_session',
      'ads.internal.min_minutes_between_impressions',
      'ads.internal.first_impression_delay_seconds',
      'ads.internal.allowed_placements',
      'ads.internal.allowed_platforms',
      'ads.internal.allowed_tiers',
    ];

    // Try to load from local storage for offline fallback
    Map<String, dynamic>? cachedConfig;
    try {
      final localDb = await AdminLocalDbService.instance;
      cachedConfig = await localDb.loadAppConfig();
    } catch (_) {}

    // If offline, return cached config immediately
    if (cachedConfig != null &&
        cachedConfig.isNotEmpty &&
        adminOfflineCacheManager.shouldUseCachedData()) {
      final config = _buildConfigStateFromMap(cachedConfig);
      _setConfigVerified(false);
      if (mounted) {
        setState(() => _hydrateConfig(config));
      } else {
        _hydrateConfig(config);
      }
      return config;
    }

    // Always fetch from server when online
    try {
      final response = await Supabase.instance.client
          .from('app_config')
          .select('config_key, config_value')
          .inFilter('config_key', keys)
          .timeout(const Duration(seconds: 10));

      final rows = List<Map<String, dynamic>>.from(response);
      final byKey = <String, dynamic>{};
      for (final row in rows) {
        final key = (row['config_key'] ?? '').toString();
        if (key.isEmpty) continue;
        byKey[key] = row['config_value'];
      }

      // A partial read means some managed keys have no row in app_config yet.
      // That is still a VERIFIED read: `inFilter` returns every matching row,
      // so a missing key genuinely has no stored value to clobber, and the
      // upsert on save will create it. Only a failed/offline read is unsafe,
      // because then the visible values may be client-side defaults standing
      // in for values we could not see.
      final missingKeys = keys.where((k) => !byKey.containsKey(k)).toList();
      if (missingKeys.isNotEmpty) {
        debugPrint(
          '[SponsoredAds] Config rows not yet present, will be created on '
          'save: $missingKeys',
        );
      }

      // Save to local storage
      try {
        final localDb = await AdminLocalDbService.instance;
        await localDb.saveAppConfig(byKey);
      } catch (_) {}

      final config = _buildConfigStateFromMap(byKey);
      _setConfigVerified(true);
      if (mounted) {
        setState(() => _hydrateConfig(config, fromServer: true));
      } else {
        _hydrateConfig(config, fromServer: true);
      }
      return config;
    } catch (e) {
      debugPrint('[SponsoredAds] Config load failed: $e');
      // If server request fails and we have cached config, return it
      if (cachedConfig != null && cachedConfig.isNotEmpty) {
        final config = _buildConfigStateFromMap(cachedConfig);
        _setConfigVerified(false);
        if (mounted) {
          setState(() => _hydrateConfig(config));
        } else {
          _hydrateConfig(config);
        }
        return config;
      }
      // Return default config as fallback, but flag it as UNVERIFIED.
      //
      // Previously this hydrated the hard-coded defaults indistinguishably
      // from a real server read, so a transient failure looked like
      // "ads are off" and saving any single toggle overwrote all 11
      // app_config rows with these defaults.
      _setConfigVerified(false);
      final defaultConfig = _SponsoredAdConfigState(
        adsEnabled: false,
        sponsoredCardsEnabled: true,
        familySafeOnly: true,
        reportEnabled: true,
        maxImpressionsPerSession: 3,
        minMinutesBetweenImpressions: 8,
        firstImpressionDelaySeconds: 90,
        allowedPlacements: const [
          'home_inline',
          'matches_inline',
          'chats_inline',
          'events_inline',
          'profile_inline',
        ],
        allowedPlatforms: const [
          'android',
          'ios',
          'web',
          'windows',
          'macos',
          'linux',
        ],
        allowedTiers: const ['free', 'plus', 'gold', 'platinum'],
      );
      if (mounted) {
        setState(() => _hydrateConfig(defaultConfig));
      } else {
        _hydrateConfig(defaultConfig);
      }
      return defaultConfig;
    }
  }

  /// Record whether the currently-displayed config was read from the server.
  /// When false the Configuration tab shows a warning and disables Save, so
  /// client-side defaults cannot overwrite real production settings.
  void _setConfigVerified(bool value) {
    if (_configVerified == value) return;
    _configVerified = value;
  }

  _SponsoredAdConfigState _buildConfigStateFromMap(Map<String, dynamic> byKey) {
    return _SponsoredAdConfigState(
      adsEnabled: _parseBoolConfig(byKey['ads.internal.enabled'], false),
      sponsoredCardsEnabled: _parseBoolConfig(
        byKey['ads.internal.sponsored_cards_enabled'],
        true,
      ),
      familySafeOnly: _parseBoolConfig(
        byKey['ads.internal.family_safe_only'],
        true,
      ),
      reportEnabled: _parseBoolConfig(
        byKey['ads.internal.report_enabled'],
        true,
      ),
      maxImpressionsPerSession: _parseIntConfig(
        byKey['ads.internal.max_impressions_per_session'],
        3,
      ),
      minMinutesBetweenImpressions: _parseIntConfig(
        byKey['ads.internal.min_minutes_between_impressions'],
        8,
      ),
      firstImpressionDelaySeconds: _parseIntConfig(
        byKey['ads.internal.first_impression_delay_seconds'],
        90,
      ),
      allowedPlacements: _parseJsonArrayConfig(
        byKey['ads.internal.allowed_placements'],
        // Must include profile_inline: the UI offers it as a master placement
        // and the DB seed includes it. Omitting it here disabled the
        // profile_inline chips with a "disabled by master" tooltip whenever
        // the config row was missing.
        const [
          'home_inline',
          'matches_inline',
          'chats_inline',
          'events_inline',
          'profile_inline',
        ],
      ),
      allowedPlatforms: _parseJsonArrayConfig(
        byKey['ads.internal.allowed_platforms'],
        const ['android', 'ios', 'web', 'windows', 'macos', 'linux'],
      ),
      allowedTiers: _parseJsonArrayConfig(
        byKey['ads.internal.allowed_tiers'],
        const ['free', 'plus', 'gold', 'platinum'],
      ),
    );
  }

  bool _parseBoolConfig(dynamic value, bool fallback) {
    if (value is bool) {
      return value;
    }
    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == 'true') {
      return true;
    }
    if (normalized == 'false') {
      return false;
    }
    return fallback;
  }

  int _parseIntConfig(dynamic value, int fallback) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString().trim() ?? '') ?? fallback;
  }

  List<String> _parseJsonArrayConfig(dynamic value, List<String> fallback) {
    if (value == null) {
      return fallback;
    }
    try {
      final List<dynamic> list;
      if (value is List) {
        list = value;
      } else {
        final json = value.toString();
        list = jsonDecode(json) as List<dynamic>;
      }
      return list.map((e) => e.toString()).toList();
    } catch (_) {
      return fallback;
    }
  }

  /// Load the translation rows for [keys] across EVERY locale that has one.
  ///
  /// The previous implementation looped a hard-coded `{'en','es','he'}` and
  /// fetched the entire translations table per locale through the
  /// `public-reference-data` edge function. That both (a) hid any campaign copy
  /// stored in other languages from the editor and (b) pulled the whole
  /// translation set three times on every campaign edit.
  ///
  /// `translations` has a public SELECT policy, so the admin app can filter
  /// server-side by key. Falls back to the edge function if that read fails.
  Future<Map<String, Map<String, String>>> _loadTranslationsForKeys(
    List<String> keys,
  ) async {
    final map = <String, Map<String, String>>{};
    final filteredKeys = keys
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (filteredKeys.isEmpty) {
      return map;
    }

    void absorb(String locale, String key, String value) {
      final normalizedKey = key.trim();
      final normalizedLocale = locale.trim().toLowerCase();
      if (normalizedKey.isEmpty ||
          normalizedLocale.isEmpty ||
          !filteredKeys.contains(normalizedKey)) {
        return;
      }
      map.putIfAbsent(
        normalizedKey,
        () => <String, String>{},
      )[normalizedLocale] = value;
    }

    try {
      final rows = await Supabase.instance.client
          .from('translations')
          .select('locale, key, value')
          .inFilter('key', filteredKeys)
          .timeout(const Duration(seconds: 15));
      for (final row in List<Map<String, dynamic>>.from(rows)) {
        absorb(
          (row['locale'] ?? '').toString(),
          (row['key'] ?? '').toString(),
          (row['value'] ?? '').toString(),
        );
      }
      return map;
    } catch (e) {
      debugPrint('[SponsoredAds] Direct translations read failed: $e');
    }

    // Fallback: edge function, all known locales.
    final locales = <String>{
      ..._availableLocaleOptions.map((o) => o.code),
      'en',
      'es',
      'he',
    };
    for (final locale in locales) {
      try {
        final rows = await publicReferenceDataService.fetchTranslations(locale);
        for (final entry in rows.entries) {
          absorb(locale, entry.key, entry.value);
        }
      } catch (e) {
        debugPrint(
          '[SponsoredAds] Translation fallback failed for $locale: $e',
        );
      }
    }
    return map;
  }

  Future<void> _saveAdConfig() async {
    final t = widget.t;
    setState(() => _isSavingConfig = true);
    try {
      final client = Supabase.instance.client;

      final payloads = [
        _configPayload(
          key: 'ads.internal.enabled',
          value: _adsEnabled,
          type: 'boolean',
          description: 'Enable/disable internal sponsored ads system',
        ),
        _configPayload(
          key: 'ads.internal.sponsored_cards_enabled',
          value: _sponsoredCardsEnabled,
          type: 'boolean',
          description:
              'Controls whether Supabase-managed sponsored cards can be shown.',
        ),
        _configPayload(
          key: 'ads.internal.family_safe_only',
          value: _familySafeOnly,
          type: 'boolean',
          description:
              'When enabled, only family-safe campaigns can be served.',
        ),
        _configPayload(
          key: 'ads.internal.report_enabled',
          value: _reportEnabled,
          type: 'boolean',
          description: 'Controls whether users can report a sponsored card.',
        ),
        _configPayload(
          key: 'ads.internal.max_impressions_per_session',
          value: _clampConfigInt(
            _maxImpressionsController.text,
            fallback: 3,
            min: 0,
            max: 20,
          ),
          type: 'number',
          description:
              'Maximum sponsored impressions allowed during a single app session.',
          minValue: 0,
          maxValue: 20,
        ),
        _configPayload(
          key: 'ads.internal.min_minutes_between_impressions',
          value: _clampConfigInt(
            _minMinutesController.text,
            fallback: 8,
            min: 0,
            max: 120,
          ),
          type: 'number',
          description:
              'Minimum pacing time between ad impressions for the same app session.',
          minValue: 0,
          maxValue: 120,
        ),
        _configPayload(
          key: 'ads.internal.first_impression_delay_seconds',
          value: _clampConfigInt(
            _firstDelaySecondsController.text,
            fallback: 90,
            min: 0,
            max: 1800,
          ),
          type: 'number',
          description:
              'Minimum delay after app start before the first ad can appear.',
          minValue: 0,
          maxValue: 1800,
        ),
        _configPayload(
          key: 'ads.internal.allowed_placements',
          value: _orderedPlacements(_masterAllowedPlacements),
          type: 'array',
          description: 'Master list of allowed placements for internal ads.',
        ),
        _configPayload(
          key: 'ads.internal.allowed_platforms',
          value: _orderedPlatforms(_masterAllowedPlatforms),
          type: 'array',
          description: 'Master list of allowed platforms for internal ads.',
        ),
        _configPayload(
          key: 'ads.internal.allowed_tiers',
          value: _orderedTiers(_masterAllowedTiers),
          type: 'array',
          description:
              'Master list of allowed subscription tiers for internal ads.',
        ),
      ];

      for (final payload in payloads) {
        // Use upsert to insert if not exists, update if exists.
        // `.select()` makes an RLS/CHECK rejection observable instead of
        // silently reporting success on a zero-row write.
        final written = await client
            .from('app_config')
            .upsert(payload, onConflict: 'config_key')
            .select('config_key');
        if (List<Map<String, dynamic>>.from(written).isEmpty) {
          throw StateError(t('adminSponsoredAdsWriteRejected'));
        }
      }
      if (!mounted) {
        return;
      }

      // Drop only the ad config keys from the local snapshot. Clearing the
      // whole box would also wipe unrelated config cached for other screens.
      try {
        final localDb = await AdminLocalDbService.instance;
        await localDb.removeAppConfigKeys(
          payloads
              .map((p) => (p['config_key'] ?? '').toString())
              .where((k) => k.isNotEmpty)
              .toList(growable: false),
        );
      } catch (_) {}

      _showSuccess(t('adminSponsoredAdsConfigSaved'));
      setState(() {
        _configHydrated = false;
        _adConfigFuture = _loadAdConfig();
      });
      // Wait for config to reload and capture new original values
      final newConfig = await _adConfigFuture;
      if (mounted && newConfig != null) {
        _captureOriginalConfigValues(newConfig);
      }
    } catch (e) {
      _showError('${t('adminSponsoredAdsConfigSaveFailed')} $e');
    } finally {
      if (mounted) {
        setState(() => _isSavingConfig = false);
      }
    }
  }

  /// Parse a numeric config field, falling back when blank/non-numeric and
  /// clamping into the documented [min]/[max] range. The server stores
  /// min_value/max_value as metadata only, so without this the admin could
  /// persist values the ad-serving RPC was never designed for.
  /// Parse an optional positive-integer field (impression caps).
  /// Blank or zero means "no limit", which is stored as NULL.
  int? _parseOptionalPositiveInt(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  int _clampConfigInt(
    String raw, {
    required int fallback,
    required int min,
    required int max,
  }) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) return fallback;
    return parsed.clamp(min, max);
  }

  Map<String, dynamic> _configPayload({
    required String key,
    required Object value,
    required String type,
    required String description,
    num? minValue,
    num? maxValue,
  }) {
    // For arrays, booleans, and numbers, pass directly so Supabase stores proper JSON types
    // For strings, pass as-is
    dynamic configValue;
    switch (type) {
      case 'boolean':
        configValue = value is bool
            ? value
            : value.toString() == 'true'; // Pass bool directly
        break;
      case 'string':
        configValue = value;
        break;
      case 'number':
        configValue = value is num
            ? value.toInt()
            : int.tryParse(value.toString()) ?? 0; // Pass int directly
        break;
      case 'array':
        // Pass the List through so Supabase stores a real JSON array. The
        // caller is responsible for supplying a deterministically ordered list
        // (see _orderedPlacements / _orderedPlatforms / _orderedTiers) so the
        // stored jsonb does not churn between saves.
        configValue = value is List ? List<dynamic>.from(value) : [value];
        break;
      default:
        configValue = value.toString();
    }

    return {
      'config_key': key,
      'config_value': configValue,
      'config_type': type,
      'category': 'ads',
      'description': description,
      'is_user_configurable': false,
      'min_value': minValue,
      'max_value': maxValue,
    };
  }

  Future<bool> _saveCampaign({
    bool navigateToCampaigns = true,
    int? targetTabIndexAfterSave,
  }) async {
    final t = widget.t;
    final internalName = _internalNameController.text.trim();
    final advertiserName = _advertiserNameController.text.trim();
    final destinationUrl = _destinationUrlController.text.trim();
    final headlineEn = _headlineEnController.text.trim();
    final bodyEn = _bodyEnController.text.trim();
    final ctaEn = _ctaEnController.text.trim();
    final sponsorEn = _sponsorEnController.text.trim();
    final imageUrl = _imageUrlController.text.trim();

    // Validate: internal name is required for identification
    if (internalName.isEmpty) {
      _showError(t('adminSponsoredAdsValidationInternalName'));
      return false;
    }
    // Validate: advertiser_name is NOT NULL in ad_campaigns. Previously the
    // form allowed it to be blank, so the insert failed with a raw
    // "null value in column" Postgres error.
    if (advertiserName.isEmpty) {
      _showError(t('adminSponsoredAdsValidationAdvertiserName'));
      return false;
    }
    // Validate: destination_url is NOT NULL in ad_campaigns (the HTTPS CHECK
    // constraint was dropped, but the NOT NULL was not).
    if (destinationUrl.isEmpty) {
      _showError(t('adminSponsoredAdsValidationDestinationUrlRequired'));
      return false;
    }
    // Validate: at least one user-facing field or image is required
    final hasUserFacingContent =
        headlineEn.isNotEmpty ||
        bodyEn.isNotEmpty ||
        ctaEn.isNotEmpty ||
        sponsorEn.isNotEmpty ||
        imageUrl.isNotEmpty;
    if (!hasUserFacingContent) {
      _showError(t('adminSponsoredAdsValidationContentRequired'));
      return false;
    }
    // Validate: at least one placement is selected
    if (_selectedPlacements.isEmpty) {
      _showError(t('adminSponsoredAdsValidationPlacementRequired'));
      return false;
    }
    // Validate: at least one platform is selected
    if (_selectedPlatforms.isEmpty) {
      _showError(t('adminSponsoredAdsValidationPlatformRequired'));
      return false;
    }
    // Validate: at least one target tier is selected
    if (_selectedTiers.isEmpty) {
      _showError(t('adminSponsoredAdsValidationTierRequired'));
      return false;
    }
    // Validate: destination URL must be HTTPS
    if (!destinationUrl.startsWith('https://')) {
      _showError(t('adminSponsoredAdsValidationDestinationUrl'));
      return false;
    }
    // Validate: ad_campaigns has CHECK (ends_at IS NULL OR ends_at > starts_at)
    final effectiveStart = _startsAt ?? DateTime.now().toUtc();
    if (_endsAt != null && !_endsAt!.isAfter(effectiveStart)) {
      _showError(t('adminSponsoredAdsValidationEndAfterStart'));
      return false;
    }

    setState(() => _isSaving = true);
    try {
      final supabase = Supabase.instance.client;
      _headlineKey ??= _translationKey('headline');
      _bodyKey ??= _translationKey('body');
      _ctaKey ??= _translationKey('cta');
      _sponsorNameKey ??= _translationKey('sponsor');
      final removedLocales = _persistedLocaleCodes.difference(
        _selectedLocaleCodes,
      );
      final blankTranslations = _blankTranslationRows();
      final selectedPlatforms = _selectedPlatforms.contains('all')
          ? _platformOptions
          : _orderedPlatforms(_selectedPlatforms);

      final campaignPayload = <String, dynamic>{
        'internal_name': internalName,
        'advertiser_name': advertiserName,
        'destination_url': destinationUrl,
        'moderation_status': _moderationStatus,
        'family_safe': _familySafe,
        'is_active': _campaignActive,
        'starts_at': effectiveStart.toIso8601String(),
        'ends_at': _endsAt?.toIso8601String(),
        'sort_priority':
            int.tryParse(_sortPriorityController.text.trim()) ?? 100,
        'target_tiers': _orderedTiers(_selectedTiers),
        'daily_impression_cap': _parseOptionalPositiveInt(
          _dailyImpressionCapController.text,
        ),
        'total_impression_cap': _parseOptionalPositiveInt(
          _totalImpressionCapController.text,
        ),
      };

      String campaignId = _editingCampaignId ?? '';
      if (campaignId.isEmpty) {
        final inserted = await supabase
            .from('ad_campaigns')
            .insert(campaignPayload)
            .select('id')
            .single();
        campaignId = (inserted['id'] ?? '').toString();
        if (campaignId.isEmpty) {
          throw StateError(t('adminSponsoredAdsWriteRejected'));
        }
      } else {
        // `.select()` makes an RLS/CHECK rejection observable. Without it a
        // zero-row update is indistinguishable from success.
        final updated = await supabase
            .from('ad_campaigns')
            .update(campaignPayload)
            .eq('id', campaignId)
            .select('id');
        if (List<Map<String, dynamic>>.from(updated).isEmpty) {
          throw StateError(t('adminSponsoredAdsWriteRejected'));
        }
      }

      // Save creatives for each selected placement and platform combination
      // Track which placement+platform combos need new creatives vs updates
      final existingCreativeIds =
          _editingCampaignPreview?.creativeIdsByPlacement ?? {};
      final imageUrl = _imageUrlController.text.trim();
      final processedCreativeIds = <String>{};
      final selectedPlacements = _orderedPlacements(_selectedPlacements);

      for (final placement in selectedPlacements) {
        for (final platform in selectedPlatforms) {
          // NOTE: `platform` must stay the platform. A previous version of the
          // offline cache wrote the placement here, which made the
          // existingCreativeIds lookup miss and duplicated creatives on save.
          final creativePayload = <String, dynamic>{
            'campaign_id': campaignId,
            'placement': placement,
            'platform': platform,
            'headline_key': _headlineKey,
            'body_key': _bodyKey,
            'cta_key': _ctaKey,
            'sponsor_name_key': _sponsorNameKey,
            'image_url': imageUrl.isEmpty ? null : imageUrl,
            'is_active': _creativeActive,
            'sort_priority':
                int.tryParse(_sortPriorityController.text.trim()) ?? 100,
          };

          final existingCreativeId = existingCreativeIds[placement]?[platform];
          if (existingCreativeId != null && existingCreativeId.isNotEmpty) {
            // Update existing creative
            final updated = await supabase
                .from('ad_creatives')
                .update(creativePayload)
                .eq('id', existingCreativeId)
                .select('id');
            if (List<Map<String, dynamic>>.from(updated).isEmpty) {
              throw StateError(t('adminSponsoredAdsWriteRejected'));
            }
            processedCreativeIds.add(existingCreativeId);
          } else {
            // Create new creative for this placement+platform combo
            final result = await supabase
                .from('ad_creatives')
                .insert(creativePayload)
                .select('id')
                .single();
            final newId = (result['id'] ?? '').toString();
            if (newId.isEmpty) {
              throw StateError(t('adminSponsoredAdsWriteRejected'));
            }
            processedCreativeIds.add(newId);
          }
        }
      }

      // Delete creatives for removed placement+platform combinations.
      // Query the latest campaign state so stale rows from older save bugs
      // cannot survive just because they were missing from the editor snapshot.
      final allCampaignCreatives = await supabase
          .from('ad_creatives')
          .select('id, placement, platform')
          .eq('campaign_id', campaignId);
      for (final rawCreative in List<Map<String, dynamic>>.from(
        allCampaignCreatives,
      )) {
        final placement = (rawCreative['placement'] ?? '').toString();
        final platform = (rawCreative['platform'] ?? '').toString();
        final creativeId = (rawCreative['id'] ?? '').toString();
        if (creativeId.isEmpty) {
          continue;
        }
        if (!selectedPlacements.contains(placement) ||
            !selectedPlatforms.contains(platform)) {
          if (!processedCreativeIds.contains(creativeId)) {
            await supabase.from('ad_creatives').delete().eq('id', creativeId);
          }
        }
      }

      final translationRows = _translationRows();
      if (translationRows.isNotEmpty) {
        await supabase.rpc(
          'admin_bulk_upsert_translations',
          params: {'p_items': translationRows},
        );
      }
      // Locales removed from the editor, plus any field the admin blanked out.
      // Blanked English is included here: writing an empty string would leave a
      // persisted empty translation and render a blank creative in the app.
      for (final localeCode in removedLocales) {
        for (final key in [
          _headlineKey!,
          _bodyKey!,
          _ctaKey!,
          _sponsorNameKey!,
        ]) {
          await supabase.rpc(
            'admin_delete_translation_locale_key',
            params: {'p_locale': localeCode, 'p_key': key},
          );
        }
      }
      for (final translation in blankTranslations) {
        await supabase.rpc(
          'admin_delete_translation_locale_key',
          params: {
            'p_locale': translation['locale'],
            'p_key': translation['key'],
          },
        );
      }

      if (!mounted) {
        return true;
      }
      final wasEditing = _editingCampaignId != null;
      _showSuccess(
        wasEditing
            ? t('adminSponsoredAdsUpdateSuccess')
            : t('adminSponsoredAdsCreateSuccess'),
      );
      _persistedLocaleCodes = {..._selectedLocaleCodes};
      _resetForm();
      // Invalidate the aggregates cache and re-read ad_campaigns from the
      // server. Previously this called localDb.clearSponsoredAds(), wiping the
      // cached campaign list; combined with the analytics cache short-circuit
      // that made the Campaigns tab render empty right after a successful save.
      await _reloadDashboardIntoState();
      if (targetTabIndexAfterSave != null) {
        _safeTabController.animateTo(targetTabIndexAfterSave);
      } else if (navigateToCampaigns) {
        _safeTabController.animateTo(2);
      }
      return true;
    } catch (e) {
      _showError('${t('adminSponsoredAdsSaveFailed')} $e');
      return false;
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _uploadImage() async {
    final t = widget.t;
    final internalName = _internalNameController.text.trim();
    if (internalName.isEmpty) {
      _showError(t('adminSponsoredAdsValidationInternalName'));
      return;
    }

    setState(() => _isUploadingImage = true);
    try {
      final picked = await FilePicker.pickFiles(type: FileType.image);
      if (picked.isEmpty) {
        return;
      }

      final file = picked.single;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        _showError(t('adminSponsoredAdsUploadFailed'));
        return;
      }

      final path = _buildStoragePath(file, bytes);
      await _deleteStorageImageIfManaged(_imageUrlController.text.trim());
      await Supabase.instance.client.storage
          .from(_imageBucket)
          .uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
              upsert: true,
              contentType: _contentTypeForFileName(file.name),
            ),
          );
      final publicUrl = Supabase.instance.client.storage
          .from(_imageBucket)
          .getPublicUrl(path);
      if (!mounted) {
        return;
      }
      setState(() {
        _imageUrlController.text = publicUrl;
      });
      _showSuccess(t('adminSponsoredAdsUploadSuccess'));
    } catch (e) {
      _showError('${t('adminSponsoredAdsUploadFailed')} $e');
    } finally {
      if (mounted) {
        setState(() => _isUploadingImage = false);
      }
    }
  }

  String _buildStoragePath(PlatformFile file, Uint8List bytes) {
    final slug = _slugify(_internalNameController.text);
    final extension = _safeExtension(file.name);
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final folder = (_editingCampaignId ?? slug).replaceAll('-', '_');
    final sizeHint = bytes.lengthInBytes;
    return 'campaigns/$folder/${timestamp}_$sizeHint.$extension';
  }

  String _safeExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) {
      return 'jpg';
    }
    final ext = fileName.substring(dot + 1).trim().toLowerCase();
    if (ext == 'jpg' ||
        ext == 'jpeg' ||
        ext == 'png' ||
        ext == 'webp' ||
        ext == 'gif') {
      return ext;
    }
    return 'jpg';
  }

  String _contentTypeForFileName(String fileName) {
    return switch (_safeExtension(fileName)) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => 'image/jpeg',
    };
  }

  Future<void> _clearImage() async {
    await _deleteStorageImageIfManaged(_imageUrlController.text.trim());
    if (!mounted) {
      return;
    }
    setState(() {
      _imageUrlController.clear();
    });
  }

  Future<void> _deleteStorageImageIfManaged(String imageUrl) async {
    final objectPath = _extractManagedStoragePath(imageUrl);
    if (objectPath == null) {
      return;
    }
    try {
      await Supabase.instance.client.storage.from(_imageBucket).remove([
        objectPath,
      ]);
    } catch (_) {}
  }

  String? _extractManagedStoragePath(String imageUrl) {
    final trimmed = imageUrl.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      return null;
    }
    final segments = uri.pathSegments;
    final bucketIndex = segments.indexOf(_imageBucket);
    if (bucketIndex == -1 || bucketIndex >= segments.length - 1) {
      return null;
    }
    return segments.sublist(bucketIndex + 1).join('/');
  }

  List<Map<String, dynamic>> _translationRows() {
    final rows = <Map<String, dynamic>>[];
    void addLocalized(
      String key,
      String Function(_SponsoredLocaleInputs) read,
    ) {
      for (final localeCode in _orderedSelectedLocaleCodes()) {
        final inputs = _localeInputsFor(localeCode);
        final localizedValue = read(inputs).trim();
        // Never write an empty string: a blank English value would persist as
        // an empty translation and render a blank creative in the app. Blanked
        // values are routed to admin_delete_translation_locale_key instead
        // (see _blankTranslationRows).
        if (localizedValue.isEmpty) {
          continue;
        }
        rows.add({'locale': localeCode, 'key': key, 'value': localizedValue});
      }
    }

    addLocalized(_headlineKey!, (inputs) => inputs.headline.text);
    addLocalized(_bodyKey!, (inputs) => inputs.body.text);
    addLocalized(_ctaKey!, (inputs) => inputs.cta.text);
    addLocalized(_sponsorNameKey!, (inputs) => inputs.sponsor.text);
    return rows;
  }

  /// Locale/key pairs whose persisted translation row must be removed because
  /// the admin blanked the field.
  ///
  /// This now includes English. Previously `localeCode == 'en'` was skipped,
  /// so clearing the English headline and saving left an empty row behind and
  /// the app rendered a blank creative.
  ///
  /// Only rows that could actually exist are emitted: a brand-new campaign has
  /// nothing persisted, and a locale the admin just added (and left blank) has
  /// no row either. Skipping those avoids a burst of pointless RPC calls.
  List<Map<String, String>> _blankTranslationRows() {
    if (_editingCampaignId == null || _persistedLocaleCodes.isEmpty) {
      return const [];
    }
    final rows = <Map<String, String>>[];

    void addIfBlank(String key, String localeCode, String value) {
      if (value.trim().isNotEmpty) return;
      if (!_persistedLocaleCodes.contains(localeCode)) return;
      rows.add({'locale': localeCode, 'key': key});
    }

    for (final localeCode in _orderedSelectedLocaleCodes()) {
      final inputs = _peekLocaleInputsFor(localeCode);
      addIfBlank(_headlineKey!, localeCode, inputs.headline.text);
      addIfBlank(_bodyKey!, localeCode, inputs.body.text);
      addIfBlank(_ctaKey!, localeCode, inputs.cta.text);
      addIfBlank(_sponsorNameKey!, localeCode, inputs.sponsor.text);
    }

    return rows;
  }

  Future<void> _loadForEditing(_SponsoredCampaignRow campaign) async {
    final isSameCampaign = _editingCampaignId == campaign.campaignId;
    if (isSameCampaign) {
      _safeTabController.animateTo(3);
      return;
    }

    final canProceed = await _resolveEditorExit(
      targetTabIndex: 3,
      closeEditorWhenClean: true,
    );
    if (!canProceed || !mounted) {
      return;
    }

    await _loadCampaignIntoEditor(campaign);
  }

  Future<void> _loadCampaignIntoEditor(_SponsoredCampaignRow campaign) async {
    setState(() {
      _isLoadingEditor = true;
      _editingCampaignPreview = campaign;
    });
    _safeTabController.animateTo(3);

    try {
      final translations = await _loadTranslationsForKeys([
        campaign.headlineKey,
        campaign.bodyKey,
        campaign.ctaKey,
        campaign.sponsorNameKey,
      ]);

      if (!mounted) {
        return;
      }

      // Every locale that actually has a stored row for this campaign's keys,
      // plus the three core locales so the admin can always fill them in.
      // Previously this collapsed to {en,es,he} because the loader only ever
      // queried those three, which hid other languages from the editor and
      // silently stopped writing them on re-save.
      final localeCodes = <String>{'en', 'es', 'he'};
      for (final localized in translations.values) {
        localeCodes.addAll(
          localized.keys
              .map((code) => code.trim().toLowerCase())
              .where((code) => code.isNotEmpty),
        );
      }
      // Only locales with at least one non-empty value are worth showing as
      // "persisted"; the rest are just empty slots the admin can fill.
      final persistedCodes = <String>{};
      for (final entry in translations.entries) {
        if (entry.value.values.any((v) => v.trim().isNotEmpty)) {
          persistedCodes.addAll(entry.value.keys);
        }
      }

      setState(() {
        _clearExtraLocaleInputs();
        _selectedLocaleCodes
          ..clear()
          ..addAll(localeCodes);
        _persistedLocaleCodes = {...persistedCodes};
        _expandedLocaleCodes
          ..clear()
          ..add('en');
        _isLoadingEditor = false;
        _editingCampaignId = campaign.campaignId;
        _headlineKey = campaign.headlineKey;
        _bodyKey = campaign.bodyKey;
        _ctaKey = campaign.ctaKey;
        _sponsorNameKey = campaign.sponsorNameKey;
        _internalNameController.text = campaign.internalName;
        _advertiserNameController.text = campaign.advertiserName;
        _destinationUrlController.text = campaign.destinationUrl;
        _imageUrlController.text = campaign.imageUrl;
        _sortPriorityController.text = campaign.sortPriority.toString();
        _dailyImpressionCapController.text =
            campaign.dailyImpressionCap?.toString() ?? '';
        _totalImpressionCapController.text =
            campaign.totalImpressionCap?.toString() ?? '';
        _moderationStatus = campaign.moderationStatus;
        _selectedPlacements
          ..clear()
          ..addAll(campaign.placements);
        _selectedPlatforms
          ..clear()
          ..addAll(
            campaign.platforms.contains('all')
                ? _platformOptions
                : campaign.platforms,
          );
        // Safe: _normalizeSelectedPlatforms only prunes at the pristine shell,
        // which is false here, so the campaign's platforms are preserved.
        _normalizeSelectedPlatforms();
        // When editing, preserve all campaign target tiers (don't filter by master)
        // Don't call _normalizeSelectedTiers here - it would remove tiers not in master list
        _selectedTiers
          ..clear()
          ..addAll(
            campaign.targetTiers.isNotEmpty
                ? campaign.targetTiers
                : _masterAllowedTiers,
          );
        _familySafe = campaign.familySafe;
        _campaignActive = campaign.isActive;
        _creativeActive = campaign.creativeIsActive;
        _startsAt = campaign.startsAt;
        _endsAt = campaign.endsAt;
        _headlineEnController.text =
            translations[campaign.headlineKey]?['en'] ?? '';
        _headlineEsController.text =
            translations[campaign.headlineKey]?['es'] ?? '';
        _headlineHeController.text =
            translations[campaign.headlineKey]?['he'] ?? '';
        _bodyEnController.text = translations[campaign.bodyKey]?['en'] ?? '';
        _bodyEsController.text = translations[campaign.bodyKey]?['es'] ?? '';
        _bodyHeController.text = translations[campaign.bodyKey]?['he'] ?? '';
        _ctaEnController.text = translations[campaign.ctaKey]?['en'] ?? '';
        _ctaEsController.text = translations[campaign.ctaKey]?['es'] ?? '';
        _ctaHeController.text = translations[campaign.ctaKey]?['he'] ?? '';
        _sponsorEnController.text =
            translations[campaign.sponsorNameKey]?['en'] ?? '';
        _sponsorEsController.text =
            translations[campaign.sponsorNameKey]?['es'] ?? '';
        _sponsorHeController.text =
            translations[campaign.sponsorNameKey]?['he'] ?? '';
        for (final localeCode in localeCodes) {
          if (localeCode == 'en' || localeCode == 'es' || localeCode == 'he') {
            continue;
          }
          final inputs = _localeInputsFor(localeCode);
          inputs.headline.text =
              translations[campaign.headlineKey]?[localeCode] ?? '';
          inputs.body.text = translations[campaign.bodyKey]?[localeCode] ?? '';
          inputs.cta.text = translations[campaign.ctaKey]?[localeCode] ?? '';
          inputs.sponsor.text =
              translations[campaign.sponsorNameKey]?[localeCode] ?? '';
        }
        _markEditorClean();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoadingEditor = false;
      });
      _showError('${widget.t('adminSponsoredAdsLoadFailed')} $e');
    }
  }

  Future<void> _toggleCampaignActive(_SponsoredCampaignRow campaign) async {
    try {
      // `.select()` so a zero-row write (RLS rejection) is not reported as
      // success. Previously the UI re-rendered the stale cached row and the
      // toggle appeared to do nothing.
      final updated = await Supabase.instance.client
          .from('ad_campaigns')
          .update({'is_active': !campaign.isActive})
          .eq('id', campaign.campaignId)
          .select('id');
      if (List<Map<String, dynamic>>.from(updated).isEmpty) {
        throw StateError(widget.t('adminSponsoredAdsWriteRejected'));
      }
      if (!mounted) {
        return;
      }
      await _reloadDashboardIntoState();
    } catch (e) {
      _showError('${widget.t('adminSponsoredAdsSaveFailed')} $e');
    }
  }

  Future<void> _deleteCampaign(_SponsoredCampaignRow campaign) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(widget.t('adminSponsoredAdsDeleteTitle')),
          content: Text(
            widget.t(
              'adminSponsoredAdsDeleteBody',
              params: {'name': campaign.internalName},
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(widget.t('generalCancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(widget.t('generalDelete')),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    try {
      // Delete the row FIRST. ad_campaigns -> ad_creatives is ON DELETE CASCADE,
      // so once the row is gone the creatives (and their image reference) are
      // unreachable. Deleting the storage object first meant a failed row
      // delete left a live campaign pointing at a removed image.
      final deleted = await Supabase.instance.client
          .from('ad_campaigns')
          .delete()
          .eq('id', campaign.campaignId)
          .select('id');
      if (List<Map<String, dynamic>>.from(deleted).isEmpty) {
        throw StateError(widget.t('adminSponsoredAdsWriteRejected'));
      }
      // Row is gone; the orphaned object is now safe to remove.
      try {
        await _deleteStorageImageIfManaged(campaign.imageUrl);
      } catch (_) {}
      if (!mounted) {
        return;
      }
      await _removeCampaignFromLocalState(campaign.campaignId);
      _showSuccess(widget.t('adminSponsoredAdsDeleteSuccess'));
      setState(() {
        if (_editingCampaignId == campaign.campaignId) {
          _clearFormFields();
        }
      });
      await _reloadDashboardIntoState();
    } catch (e) {
      _showError('${widget.t('adminSponsoredAdsDeleteFailed')} $e');
    }
  }

  Future<void> _applyDemoPreset() async {
    final canProceed = await _resolveEditorExit(
      targetTabIndex: 3,
      closeEditorWhenClean: true,
    );
    if (!canProceed || !mounted) {
      return;
    }

    setState(() {
      _clearFormFields();
      _internalNameController.text = 'demo_family_safety_partner_card';
      _advertiserNameController.text = 'MatchMe Family Safety Demo';
      _destinationUrlController.text = 'https://example.com/';
      _sortPriorityController.text = '100';
      _moderationStatus = 'approved';
      _selectedPlacements
        ..clear()
        ..add('home_inline');
      _familySafe = true;
      _campaignActive = true;
      _creativeActive = true;
      _startsAt = DateTime.now().toUtc();
      _endsAt = null;
      _headlineEnController.text = 'Family-friendly local events';
      _headlineEsController.text = 'Eventos locales para toda la familia';
      _headlineHeController.text = 'אירועים מקומיים לכל המשפחה';
      _bodyEnController.text =
          'Discover safe community events and activity ideas for all ages.';
      _bodyEsController.text =
          'Descubre eventos comunitarios seguros e ideas de actividades para todas las edades.';
      _bodyHeController.text =
          'גלו אירועים קהילתיים בטוחים ורעיונות לפעילויות לכל הגילאים.';
      _ctaEnController.text = 'Learn more';
      _ctaEsController.text = 'Más información';
      _ctaHeController.text = 'למידע נוסף';
      _sponsorEnController.text = 'MatchMe Family Safety Demo';
      _sponsorEsController.text =
          'Demostración de seguridad familiar de MatchMe';
      _sponsorHeController.text = 'הדגמת בטיחות משפחתית של MatchMe';
    });
    _safeTabController.animateTo(3);
  }

  Future<void> _cancelEditing() async {
    final canProceed = await _resolveEditorExit(closeEditorWhenClean: true);
    if (!canProceed || !mounted) {
      return;
    }
    setState(() {});
  }

  void _resetForm() {
    setState(() {
      _clearFormFields();
    });
  }

  void _clearFormFields() {
    _clearExtraLocaleInputs();
    _selectedLocaleCodes
      ..clear()
      ..addAll(const {'en', 'es', 'he'});
    _persistedLocaleCodes = <String>{};
    _expandedLocaleCodes
      ..clear()
      ..add('en');
    _editingCampaignId = null;
    _editingCampaignPreview = null;
    _isLoadingEditor = false;
    _headlineKey = null;
    _bodyKey = null;
    _ctaKey = null;
    _sponsorNameKey = null;
    _internalNameController.clear();
    _advertiserNameController.clear();
    _destinationUrlController.clear();
    _imageUrlController.clear();
    _sortPriorityController.text = '100';
    _dailyImpressionCapController.clear();
    _totalImpressionCapController.clear();
    _moderationStatus = 'draft';
    _selectedPlacements
      ..clear()
      ..add('home_inline');
    _selectedPlatforms
      ..clear()
      ..addAll(_masterAllowedPlatforms);
    _selectedTiers
      ..clear()
      ..addAll(_masterAllowedTiers);
    _familySafe = true;
    _campaignActive = true;
    _creativeActive = true;
    _startsAt = null;
    _endsAt = null;
    _headlineEnController.clear();
    _headlineEsController.clear();
    _headlineHeController.clear();
    _bodyEnController.clear();
    _bodyEsController.clear();
    _bodyHeController.clear();
    _ctaEnController.clear();
    _ctaEsController.clear();
    _ctaHeController.clear();
    _sponsorEnController.clear();
    _sponsorEsController.clear();
    _sponsorHeController.clear();
    _markEditorClean();
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
}

enum _SponsoredEditorExitAction { save, discard, cancel }

class _SponsoredLocaleOption {
  const _SponsoredLocaleOption({required this.code, required this.displayName});

  final String code;
  final String displayName;
}

class _SponsoredLocaleInputs {
  _SponsoredLocaleInputs({
    required this.headline,
    required this.body,
    required this.cta,
    required this.sponsor,
    required this.ownsControllers,
  });

  /// Shared, non-owning placeholder used by read-only lookups for a locale
  /// whose controllers do not exist yet. Never dispose it.
  static final _SponsoredLocaleInputs _empty = _SponsoredLocaleInputs.borrowed(
    headline: TextEditingController(),
    body: TextEditingController(),
    cta: TextEditingController(),
    sponsor: TextEditingController(),
  );

  factory _SponsoredLocaleInputs.create() {
    return _SponsoredLocaleInputs(
      headline: TextEditingController(),
      body: TextEditingController(),
      cta: TextEditingController(),
      sponsor: TextEditingController(),
      ownsControllers: true,
    );
  }

  factory _SponsoredLocaleInputs.borrowed({
    required TextEditingController headline,
    required TextEditingController body,
    required TextEditingController cta,
    required TextEditingController sponsor,
  }) {
    return _SponsoredLocaleInputs(
      headline: headline,
      body: body,
      cta: cta,
      sponsor: sponsor,
      ownsControllers: false,
    );
  }

  final TextEditingController headline;
  final TextEditingController body;
  final TextEditingController cta;
  final TextEditingController sponsor;
  final bool ownsControllers;

  /// Read-only placeholder for a locale with no controllers yet.
  static _SponsoredLocaleInputs empty() => _empty;

  void dispose() {
    if (!ownsControllers) {
      return;
    }
    headline.dispose();
    body.dispose();
    cta.dispose();
    sponsor.dispose();
  }
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Order-insensitive list comparison.
///
/// Used for the editor draft, whose placement/tier lists come from Sets.
/// Deselecting then re-selecting a chip changes the Set's iteration order, so
/// an order-sensitive compare reported a false "unsaved changes" diff and
/// popped the discard dialog on an otherwise clean form.
bool _sameMembers(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  return a.toSet().containsAll(b.toSet());
}

class _SponsoredEditorDraft {
  const _SponsoredEditorDraft({
    required this.internalName,
    required this.advertiserName,
    required this.destinationUrl,
    required this.imageUrl,
    required this.sortPriority,
    required this.dailyCap,
    required this.totalCap,
    required this.moderationStatus,
    required this.placements,
    required this.platformSignature,
    required this.familySafe,
    required this.campaignActive,
    required this.creativeActive,
    required this.startsAtIso,
    required this.endsAtIso,
    required this.headlineEn,
    required this.headlineEs,
    required this.headlineHe,
    required this.bodyEn,
    required this.bodyEs,
    required this.bodyHe,
    required this.ctaEn,
    required this.ctaEs,
    required this.ctaHe,
    required this.sponsorEn,
    required this.sponsorEs,
    required this.sponsorHe,
    required this.localeSignature,
    required this.targetTiers,
  });

  /// Baseline for a blank editor.
  ///
  /// Every value here MUST match what `_clearFormFields()` + `_markEditorClean()`
  /// produce, otherwise `_hasUnsavedEditorChanges` is true on a pristine form
  /// and the discard dialog appears without the admin typing anything.
  /// The previous version claimed two placements and a locale signature with
  /// the wrong arity, which did not match the real defaults.
  const _SponsoredEditorDraft.empty()
    : internalName = '',
      advertiserName = '',
      destinationUrl = '',
      imageUrl = '',
      sortPriority = '100',
      dailyCap = '',
      totalCap = '',
      moderationStatus = 'draft',
      placements = const ['home_inline'],
      // Placeholder: _markEditorClean() in initState replaces this with the
      // real master-platform signature before the first build.
      platformSignature = '',
      familySafe = true,
      campaignActive = true,
      creativeActive = true,
      startsAtIso = '',
      endsAtIso = '',
      headlineEn = '',
      headlineEs = '',
      headlineHe = '',
      bodyEn = '',
      bodyEs = '',
      bodyHe = '',
      ctaEn = '',
      ctaEs = '',
      ctaHe = '',
      sponsorEn = '',
      sponsorEs = '',
      sponsorHe = '',
      // Placeholder: replaced by _markEditorClean() in initState. The previous
      // hard-coded string had the wrong arity for _buildLocaleSignature().
      localeSignature = '',
      targetTiers = const ['free'];

  final String internalName;
  final String advertiserName;
  final String destinationUrl;
  final String imageUrl;
  final String sortPriority;
  final String dailyCap;
  final String totalCap;
  final String moderationStatus;
  final List<String> placements;
  final String platformSignature;
  final bool familySafe;
  final bool campaignActive;
  final bool creativeActive;
  final String startsAtIso;
  final String endsAtIso;
  final String headlineEn;
  final String headlineEs;
  final String headlineHe;
  final String bodyEn;
  final String bodyEs;
  final String bodyHe;
  final String ctaEn;
  final String ctaEs;
  final String ctaHe;
  final String sponsorEn;
  final String sponsorEs;
  final String sponsorHe;
  final String localeSignature;
  final List<String> targetTiers;

  @override
  bool operator ==(Object other) {
    return other is _SponsoredEditorDraft &&
        other.internalName == internalName &&
        other.advertiserName == advertiserName &&
        other.destinationUrl == destinationUrl &&
        other.imageUrl == imageUrl &&
        other.sortPriority == sortPriority &&
        other.dailyCap == dailyCap &&
        other.totalCap == totalCap &&
        other.moderationStatus == moderationStatus &&
        // Order-insensitive: these come from Sets, whose iteration order is
        // insertion order. Deselecting then re-selecting a tier or placement
        // reorders the list, which previously reported a false "unsaved
        // changes" diff and popped the discard dialog on a clean form.
        _sameMembers(other.placements, placements) &&
        other.platformSignature == platformSignature &&
        other.familySafe == familySafe &&
        other.campaignActive == campaignActive &&
        other.creativeActive == creativeActive &&
        other.startsAtIso == startsAtIso &&
        other.endsAtIso == endsAtIso &&
        other.headlineEn == headlineEn &&
        other.headlineEs == headlineEs &&
        other.headlineHe == headlineHe &&
        other.bodyEn == bodyEn &&
        other.bodyEs == bodyEs &&
        other.bodyHe == bodyHe &&
        other.ctaEn == ctaEn &&
        other.ctaEs == ctaEs &&
        other.ctaHe == ctaHe &&
        other.sponsorEn == sponsorEn &&
        other.sponsorEs == sponsorEs &&
        other.sponsorHe == sponsorHe &&
        other.localeSignature == localeSignature &&
        _sameMembers(other.targetTiers, targetTiers);
  }

  @override
  int get hashCode => Object.hashAll([
    internalName,
    advertiserName,
    destinationUrl,
    imageUrl,
    sortPriority,
    dailyCap,
    totalCap,
    moderationStatus,
    // Unordered, to match the order-insensitive `==` above.
    Object.hashAllUnordered(placements),
    platformSignature,
    familySafe,
    campaignActive,
    creativeActive,
    startsAtIso,
    endsAtIso,
    headlineEn,
    headlineEs,
    headlineHe,
    bodyEn,
    bodyEs,
    bodyHe,
    ctaEn,
    ctaEs,
    ctaHe,
    sponsorEn,
    sponsorEs,
    sponsorHe,
    localeSignature,
    Object.hashAllUnordered(targetTiers),
  ]);
}

class _SponsoredCampaignRow {
  const _SponsoredCampaignRow({
    required this.campaignId,
    required this.creativeId,
    required this.internalName,
    required this.advertiserName,
    required this.destinationUrl,
    required this.moderationStatus,
    required this.familySafe,
    required this.isActive,
    required this.startsAt,
    required this.endsAt,
    required this.sortPriority,
    required this.placement,
    required this.placements,
    required this.creativeIdsByPlacement,
    required this.platform,
    required this.platforms,
    required this.targetTiers,
    required this.imageUrl,
    required this.creativeIsActive,
    required this.headlineKey,
    required this.bodyKey,
    required this.ctaKey,
    required this.sponsorNameKey,
    required this.headlinePreview,
    required this.bodyPreview,
    this.dailyImpressionCap,
    this.totalImpressionCap,
  });

  final String campaignId;
  final String creativeId;
  final String internalName;
  final String advertiserName;
  final String destinationUrl;
  final String moderationStatus;
  final bool familySafe;
  final bool isActive;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final int sortPriority;
  final String placement;
  final List<String> placements;
  final Map<String, Map<String, String>> creativeIdsByPlacement;
  final String platform;
  final List<String> platforms;
  final List<String> targetTiers;
  final String imageUrl;
  final bool creativeIsActive;
  final String headlineKey;
  final String bodyKey;
  final String ctaKey;
  final String sponsorNameKey;
  final String headlinePreview;
  final String bodyPreview;
  final int? dailyImpressionCap;
  final int? totalImpressionCap;

  Map<String, dynamic> toMap() {
    final creatives = creativeIdsByPlacement.entries
        .expand((placementEntry) {
          return placementEntry.value.entries.map((platformEntry) {
            return <String, dynamic>{
              'id': platformEntry.value,
              'placement': placementEntry.key,
              // NOTE: must be the platform key. This previously wrote
              // `placementEntry.key`, which corrupted the cached creative so
              // the editor could never match an existing creative and
              // re-INSERTed a duplicate on every save.
              'platform': platformEntry.key,
              'headline_key': headlineKey,
              'body_key': bodyKey,
              'cta_key': ctaKey,
              'sponsor_name_key': sponsorNameKey,
              'image_url': imageUrl,
              'is_active': creativeIsActive,
              'sort_priority': sortPriority,
            };
          });
        })
        .toList(growable: false);

    return {
      'id': campaignId,
      'internal_name': internalName,
      'advertiser_name': advertiserName,
      'destination_url': destinationUrl,
      'moderation_status': moderationStatus,
      'family_safe': familySafe,
      'is_active': isActive,
      'starts_at': startsAt?.toIso8601String(),
      'ends_at': endsAt?.toIso8601String(),
      'sort_priority': sortPriority,
      'placement': placement,
      'platform': platform,
      // Persisted so the offline path does not silently fall back to ['free'].
      'target_tiers': targetTiers,
      'daily_impression_cap': dailyImpressionCap,
      'total_impression_cap': totalImpressionCap,
      // Resolved copy, so cached cards keep their headline/body and stay
      // searchable instead of rendering blank.
      'headline_preview': headlinePreview,
      'body_preview': bodyPreview,
      'updated_at': DateTime.now().toIso8601String(),
      'ad_creatives': creatives.isEmpty
          ? [
              {
                'id': creativeId,
                'placement': placement,
                'platform': platform,
                'headline_key': headlineKey,
                'body_key': bodyKey,
                'cta_key': ctaKey,
                'sponsor_name_key': sponsorNameKey,
                'image_url': imageUrl,
                'is_active': creativeIsActive,
                'sort_priority': sortPriority,
              },
            ]
          : creatives,
    };
  }
}

class _SponsoredCampaignMetrics {
  const _SponsoredCampaignMetrics({
    required this.campaignId,
    required this.impressions,
    required this.clicks,
    required this.reports,
    required this.ctrPercent,
    this.lastImpressionAt,
    this.lastClickAt,
  });

  final String campaignId;
  final int impressions;
  final int clicks;
  final int reports;
  final double ctrPercent;
  final DateTime? lastImpressionAt;
  final DateTime? lastClickAt;

  factory _SponsoredCampaignMetrics.fromMap(Map<String, dynamic> data) {
    return _SponsoredCampaignMetrics(
      campaignId: (data['campaign_id'] ?? '').toString(),
      impressions: (data['impressions'] as num?)?.toInt() ?? 0,
      clicks: (data['clicks'] as num?)?.toInt() ?? 0,
      reports: (data['reports'] as num?)?.toInt() ?? 0,
      ctrPercent: (data['ctr_percent'] as num?)?.toDouble() ?? 0,
      lastImpressionAt: DateTime.tryParse(
        (data['last_impression_at'] ?? '').toString(),
      ),
      lastClickAt: DateTime.tryParse((data['last_click_at'] ?? '').toString()),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'campaign_id': campaignId,
      'impressions': impressions,
      'clicks': clicks,
      'reports': reports,
      'ctr_percent': ctrPercent,
      'last_impression_at': lastImpressionAt?.toIso8601String(),
      'last_click_at': lastClickAt?.toIso8601String(),
    };
  }
}

class _SponsoredCampaignReportSummary {
  const _SponsoredCampaignReportSummary({
    required this.campaignId,
    required this.reportCount,
    required this.uniqueReporterCount,
    required this.lastReportedAt,
    required this.latestReason,
    required this.latestDetails,
    required this.latestPlacement,
  });

  final String campaignId;
  final int reportCount;
  final int uniqueReporterCount;
  final DateTime? lastReportedAt;
  final String latestReason;
  final String latestDetails;
  final String latestPlacement;

  factory _SponsoredCampaignReportSummary.fromMap(Map<String, dynamic> data) {
    return _SponsoredCampaignReportSummary(
      campaignId: (data['campaign_id'] ?? '').toString(),
      reportCount: (data['report_count'] as num?)?.toInt() ?? 0,
      uniqueReporterCount:
          (data['unique_reporter_count'] as num?)?.toInt() ?? 0,
      lastReportedAt: DateTime.tryParse(
        (data['last_reported_at'] ?? '').toString(),
      )?.toUtc(),
      latestReason: (data['latest_reason'] ?? '').toString(),
      latestDetails: (data['latest_details'] ?? '').toString(),
      latestPlacement: (data['latest_placement'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'campaign_id': campaignId,
      'report_count': reportCount,
      'unique_reporter_count': uniqueReporterCount,
      'last_reported_at': lastReportedAt?.toIso8601String(),
      'latest_reason': latestReason,
      'latest_details': latestDetails,
      'latest_placement': latestPlacement,
    };
  }

  factory _SponsoredCampaignReportSummary.fromReports(
    String campaignId,
    List<_SponsoredReportRow> reports,
  ) {
    final sorted = [...reports]
      ..sort((a, b) {
        final aTime = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });
    final latest = sorted.isEmpty ? null : sorted.first;
    final uniqueReporterCount = sorted
        .map((report) => report.reporterUserId.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .length;
    return _SponsoredCampaignReportSummary(
      campaignId: campaignId,
      reportCount: sorted.length,
      uniqueReporterCount: uniqueReporterCount,
      lastReportedAt: latest?.createdAt,
      latestReason: latest?.reason ?? '',
      latestDetails: latest?.details ?? '',
      latestPlacement: latest?.placement ?? '',
    );
  }
}

class _SponsoredCampaignEventRow {
  const _SponsoredCampaignEventRow({
    required this.eventId,
    required this.eventType,
    required this.campaignId,
    required this.creativeId,
    required this.userId,
    required this.userName,
    required this.placement,
    required this.platform,
    required this.locale,
    required this.destinationUrl,
    required this.createdAt,
  });

  final String eventId;
  final String eventType;
  final String campaignId;
  final String creativeId;
  final String userId;
  final String userName;
  final String placement;
  final String platform;
  final String locale;
  final String destinationUrl;
  final DateTime? createdAt;

  factory _SponsoredCampaignEventRow.fromMap(Map<String, dynamic> data) {
    return _SponsoredCampaignEventRow(
      eventId: (data['event_id'] ?? '').toString(),
      eventType: (data['event_type'] ?? '').toString(),
      campaignId: (data['campaign_id'] ?? '').toString(),
      creativeId: (data['creative_id'] ?? '').toString(),
      userId: (data['user_id'] ?? '').toString(),
      userName: (data['user_name'] ?? '').toString(),
      placement: (data['placement'] ?? '').toString(),
      platform: (data['platform'] ?? '').toString(),
      locale: (data['locale'] ?? '').toString(),
      destinationUrl: (data['destination_url'] ?? '').toString(),
      createdAt: DateTime.tryParse(
        (data['created_at'] ?? '').toString(),
      )?.toUtc(),
    );
  }
}

class _SponsoredCampaignEventUserSummary {
  const _SponsoredCampaignEventUserSummary({
    required this.userId,
    required this.userName,
    required this.eventCount,
    required this.lastEventAt,
    required this.placements,
    required this.platforms,
    required this.locales,
    required this.destinationUrls,
  });

  final String userId;
  final String userName;
  final int eventCount;
  final DateTime? lastEventAt;
  final List<String> placements;
  final List<String> platforms;
  final List<String> locales;
  final List<String> destinationUrls;

  factory _SponsoredCampaignEventUserSummary.fromEvents(
    List<_SponsoredCampaignEventRow> events,
  ) {
    final first = events.isEmpty ? null : events.first;
    List<String> distinctNonEmpty(Iterable<String> values) {
      return values
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false);
    }

    return _SponsoredCampaignEventUserSummary(
      userId: first?.userId ?? '',
      userName: first?.userName ?? '',
      eventCount: events.length,
      lastEventAt: first?.createdAt,
      placements: distinctNonEmpty(events.map((event) => event.placement)),
      platforms: distinctNonEmpty(events.map((event) => event.platform)),
      locales: distinctNonEmpty(events.map((event) => event.locale)),
      destinationUrls: distinctNonEmpty(
        events.map((event) => event.destinationUrl),
      ),
    );
  }
}

class _SponsoredReportRow {
  const _SponsoredReportRow({
    required this.reportId,
    required this.campaignId,
    required this.creativeId,
    required this.reporterUserId,
    required this.reporterName,
    this.internalName = '',
    required this.placement,
    required this.reason,
    required this.details,
    required this.createdAt,
  });

  final String reportId;
  final String campaignId;
  final String creativeId;
  final String reporterUserId;
  final String reporterName;
  final String internalName;
  final String placement;
  final String reason;
  final String details;
  final DateTime? createdAt;

  factory _SponsoredReportRow.fromMap(Map<String, dynamic> data) {
    return _SponsoredReportRow(
      reportId: (data['report_id'] ?? '').toString(),
      campaignId: (data['campaign_id'] ?? '').toString(),
      creativeId: (data['creative_id'] ?? '').toString(),
      reporterUserId: (data['reporter_user_id'] ?? '').toString(),
      reporterName: (data['reporter_name'] ?? '').toString(),
      internalName: (data['internal_name'] ?? '').toString(),
      placement: (data['placement'] ?? '').toString(),
      reason: (data['reason'] ?? '').toString(),
      details: (data['details'] ?? '').toString(),
      createdAt: DateTime.tryParse(
        (data['created_at'] ?? '').toString(),
      )?.toUtc(),
    );
  }
}

class _SponsoredAdConfigState {
  const _SponsoredAdConfigState({
    required this.adsEnabled,
    required this.sponsoredCardsEnabled,
    required this.familySafeOnly,
    required this.reportEnabled,
    required this.maxImpressionsPerSession,
    required this.minMinutesBetweenImpressions,
    required this.firstImpressionDelaySeconds,
    this.allowedPlacements = const [
      'home_inline',
      'matches_inline',
      'chats_inline',
      'events_inline',
      'profile_inline',
    ],
    this.allowedPlatforms = const [
      'android',
      'ios',
      'web',
      'windows',
      'macos',
      'linux',
    ],
    this.allowedTiers = const ['free', 'plus', 'gold', 'platinum'],
  });

  final bool adsEnabled;
  final bool sponsoredCardsEnabled;
  final bool familySafeOnly;
  final bool reportEnabled;
  final int maxImpressionsPerSession;
  final int minMinutesBetweenImpressions;
  final int firstImpressionDelaySeconds;
  final List<String> allowedPlacements;
  final List<String> allowedPlatforms;
  final List<String> allowedTiers;
}

class _SponsoredDashboardData {
  const _SponsoredDashboardData({
    this.campaigns = const [],
    this.metricsByCampaign = const {},
    this.recentReports = const [],
    this.reportSummariesByCampaign = const {},
  });

  final List<_SponsoredCampaignRow> campaigns;
  final Map<String, _SponsoredCampaignMetrics> metricsByCampaign;
  final List<_SponsoredReportRow> recentReports;
  final Map<String, _SponsoredCampaignReportSummary> reportSummariesByCampaign;

  _SponsoredCampaignMetrics get totalMetrics {
    var impressions = 0;
    var clicks = 0;
    var reports = 0;
    for (final metric in metricsByCampaign.values) {
      impressions += metric.impressions;
      clicks += metric.clicks;
      reports += metric.reports;
    }
    final ctr = impressions == 0 ? 0.0 : (clicks / impressions) * 100;
    return _SponsoredCampaignMetrics(
      campaignId: '',
      impressions: impressions,
      clicks: clicks,
      reports: reports,
      ctrPercent: ctr,
      lastImpressionAt: lastImpressionAt,
      lastClickAt: lastClickAt,
    );
  }

  /// Most recent impression timestamp across all campaigns.
  DateTime? get lastImpressionAt {
    DateTime? latest;
    for (final m in metricsByCampaign.values) {
      final t = m.lastImpressionAt;
      if (t != null && (latest == null || t.isAfter(latest))) latest = t;
    }
    return latest;
  }

  /// Most recent click timestamp across all campaigns.
  DateTime? get lastClickAt {
    DateTime? latest;
    for (final m in metricsByCampaign.values) {
      final t = m.lastClickAt;
      if (t != null && (latest == null || t.isAfter(latest))) latest = t;
    }
    return latest;
  }

  /// Most recent report timestamp across all campaigns.
  DateTime? get lastReportAt {
    DateTime? latest;
    for (final s in reportSummariesByCampaign.values) {
      final t = s.lastReportedAt;
      if (t != null && (latest == null || t.isAfter(latest))) latest = t;
    }
    return latest;
  }
}
