import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/sponsored_ad.dart';
import 'package:matchme/providers/ad_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/services/external_ad_service.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/widgets/banner_ad_widget.dart';
import 'package:matchme/widgets/native_ad_widget.dart';
import 'package:matchme/widgets/sponsored_card.dart';
import 'package:matchme/widgets/web_banner_ad_widget.dart';
import 'package:matchme/widgets/web_display_ad_widget.dart';
import 'package:matchme/widgets/web_in_feed_ad_widget.dart';
import 'package:matchme/widgets/web_article_ad_widget.dart';

/// Ad slot with support for both internal and external ads
///
/// Display behavior (controlled by admin toggles):
///
/// If Both Ad Systems Enabled by Admin:
/// - Shows both external and internal ads, one under the other
/// - Order is controlled by ads.display_order config ('external_first' or 'internal_first')
///
/// If Only External Ads Enabled by Admin:
/// - Shows external ads (banner, native, display, in-feed, article)
///
/// If Only Internal Ads Enabled by Admin:
/// - Shows internal sponsored ads
///
/// If Both Disabled by Admin:
/// - Nothing (empty slot)
///
/// Automatically detects platform and shows appropriate ad format:
/// - Mobile (iOS/Android): banner, native, interstitial, rewarded
/// - Web: banner, display, in-feed, article
class AdSlot extends ConsumerStatefulWidget {
  const AdSlot({
    super.key,
    required this.placement,
    this.embedded = false,
    this.adFormat =
        'banner', // 'banner', 'native', 'display', 'in_feed', 'article'
  });

  final AdPlacement placement;
  final bool embedded;
  final String adFormat;

  @override
  ConsumerState<AdSlot> createState() => _AdSlotState();
}

class _AdSlotState extends ConsumerState<AdSlot>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  bool _lastExternalEnabled = false;
  bool _lastInternalEnabled = false;
  bool _wasPaused =
      false; // Track if app was actually paused (backgrounded or screen off)
  bool _tabWasEverVisible = false;
  Widget?
  _cachedExternalAdWidget; // Stable BannerAdWidget tree — rebuilt only when unit id changes
  String? _cachedExternalAdUnitId; // Unit id backing _cachedExternalAdWidget
  Widget? _cachedSponsoredAdWidget; // Cache sponsored ad widget
  String?
  _cachedSponsoredCreativeId; // Creative id backing _cachedSponsoredAdWidget
  int _lastSeenAdEpoch =
      -1; // adConfigEpochProvider value backing the cached widgets above
  Timer? _retryTimer;
  Timer? _sponsoredRetryTimer;
  VoidCallback? _supabaseResumeDispose;
  final GlobalKey _bannerAdWidgetKey = GlobalKey();
  // NOTE: _connectivityListenerRegistered removed — ref.listen() inside build() is
  // already idempotent in Riverpod (re-subscribes per rebuild but correctly deduped).

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _supabaseResumeDispose = onSupabaseResume(_refreshCurrentScreenAds);
  }

  @override
  void reassemble() {
    super.reassemble();
    _tabWasEverVisible = false;
    _cachedExternalAdWidget = null;
    _cachedExternalAdUnitId = null;
    _cachedSponsoredAdWidget = null;
    _cachedSponsoredCreativeId = null;
    BannerAdWidget.resetStaticState();
  }

  String _getExternalPlacement() {
    switch (widget.placement) {
      case AdPlacement.homeInline:
        return 'home_inline';
      case AdPlacement.matchesInline:
        return 'matches_inline';
      case AdPlacement.chatsInline:
        return 'chats_inline';
      case AdPlacement.eventsInline:
        return 'events_inline';
      case AdPlacement.profileInline:
        return 'profile_inline';
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final currentIndex = ref.watch(navigationIndexProvider);
    final isCurrentTab = _isCurrentMainTab(currentIndex);
    final externalPlacement = _getExternalPlacement();

    ref.watch(externalAdsRealtimeProvider);

    // Check which ad system is enabled (direct values from providers)
    final externalEnabled = ref.watch(externalAdsEnabledProvider);
    final internalEnabled = ref.watch(internalAdsEnabledProvider);
    final displayOrder = ref.watch(adDisplayOrderProvider);

    // When the admin changes anything in the ad systems the epoch provider
    // bumps (via the app_config realtime stream) — cached ad widgets must not
    // outlive it, or a campaign/unit that was just toggled off would stay on
    // screen indefinitely.
    final adEpoch = ref.watch(adConfigEpochProvider);
    if (_lastSeenAdEpoch == -1) {
      _lastSeenAdEpoch = adEpoch;
    } else if (adEpoch != _lastSeenAdEpoch) {
      _lastSeenAdEpoch = adEpoch;
      _cachedSponsoredAdWidget = null;
      _cachedSponsoredCreativeId = null;
      _cachedExternalAdWidget = null;
      _cachedExternalAdUnitId = null;
    }

    if (isCurrentTab) {
      _tabWasEverVisible = true;
    }

    final shouldRetain = isCurrentTab || _tabWasEverVisible;

    // Warm provider cache for visited tabs (metadata); RPC debounced in provider.
    if (externalEnabled && shouldRetain) {
      ref.watch(externalAdProvider(externalPlacement));
    }
    if (internalEnabled && shouldRetain) {
      ref.watch(sponsoredAdProvider(widget.placement));
    }

    // Check if configuration changed
    final configChanged =
        externalEnabled != _lastExternalEnabled ||
        internalEnabled != _lastInternalEnabled;

    if (configChanged) {
      _lastExternalEnabled = externalEnabled;
      _lastInternalEnabled = internalEnabled;
    }

    if (!isCurrentTab) {
      _cancelRetryTimer();
      _cancelSponsoredRetryTimer();
    }

    if (!externalEnabled && !internalEnabled) {
      return const SizedBox.shrink();
    }

    if (!shouldRetain) {
      return const SizedBox.shrink();
    }

    final Widget slotContent;
    if (externalEnabled && !internalEnabled) {
      slotContent = _buildExternalAd(context, isTabVisible: isCurrentTab);
    } else if (!externalEnabled && internalEnabled) {
      slotContent = _buildSponsoredAd(context);
    } else {
      final externalWidget = _buildExternalAd(
        context,
        isTabVisible: isCurrentTab,
      );
      final internalWidget = _buildSponsoredAd(context);
      final firstAd = displayOrder == 'internal_first'
          ? internalWidget
          : externalWidget;
      final secondAd = displayOrder == 'internal_first'
          ? externalWidget
          : internalWidget;
      slotContent = Column(
        mainAxisSize: MainAxisSize.min,
        children: [firstAd, secondAd],
      );
    }

    // Hide off-tab slots but keep [BannerAdWidget] mounted (loaded ad cached; no [AdWidget]).
    if (!isCurrentTab) {
      return Offstage(offstage: true, child: slotContent);
    }
    return slotContent;
  }

  bool _isCurrentMainTab(int currentIndex) {
    return switch (widget.placement) {
      AdPlacement.homeInline => currentIndex == 0,
      AdPlacement.matchesInline => currentIndex == 1,
      AdPlacement.chatsInline => currentIndex == 2,
      AdPlacement.eventsInline => currentIndex == 3,
      AdPlacement.profileInline => currentIndex == 4,
    };
  }

  void _refreshCurrentScreenAds() {
    if (!mounted || !_isCurrentMainTab(ref.read(navigationIndexProvider))) {
      return;
    }

    final externalPlacement = _getExternalPlacement();
    debugPrint(
      '[AdSlot] Supabase resumed - refreshing ads for $externalPlacement',
    );
    ref.invalidate(externalAdProvider(externalPlacement));
    ref.invalidate(sponsoredAdProvider(widget.placement));
  }

  @override
  void didUpdateWidget(covariant AdSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset cache if placement or format changed
    if (oldWidget.placement != widget.placement ||
        oldWidget.adFormat != widget.adFormat ||
        oldWidget.embedded != widget.embedded) {
      _cachedExternalAdWidget = null;
      _cachedExternalAdUnitId = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // App was backgrounded or screen turned off
      _wasPaused = true;
    } else if (state == AppLifecycleState.resumed && _wasPaused) {
      // App resumed from paused state (not just inactive)
      _wasPaused = false;
      // Mark app as resumed globally to prevent ad reloads across widget recreation
      ref.read(appResumeNotifierProvider.notifier).markResumed();
    }
  }

  void _startRetryTimer(String placement) {
    if (_retryTimer != null) return;
    final isOnline = ref.read(connectivityProvider).value ?? false;
    if (!isOnline) return;
    _retryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) {
        _cancelRetryTimer();
        return;
      }
      final externalEnabled = ref.read(externalAdsEnabledProvider);
      if (!externalEnabled) {
        _cancelRetryTimer();
        return;
      }
      ref.invalidate(externalAdProvider(placement));
    });
  }

  void _cancelRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _startSponsoredRetryTimer(AdPlacement placement) {
    if (_sponsoredRetryTimer != null) return;
    final isOnline = ref.read(connectivityProvider).value ?? false;
    if (!isOnline) return;
    _sponsoredRetryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) {
        _cancelSponsoredRetryTimer();
        return;
      }
      final internalEnabled = ref.read(internalAdsEnabledProvider);
      if (!internalEnabled) {
        _cancelSponsoredRetryTimer();
        return;
      }
      ref.invalidate(sponsoredAdProvider(placement));
    });
  }

  void _cancelSponsoredRetryTimer() {
    _sponsoredRetryTimer?.cancel();
    _sponsoredRetryTimer = null;
  }

  /// Build external ad based on platform and format
  Widget _buildExternalAd(BuildContext context, {required bool isTabVisible}) {
    // Watch the resume provider so widget rebuilds when resume state changes
    ref.watch(appResumeNotifierProvider);
    final resumeNotifier = ref.read(appResumeNotifierProvider.notifier);
    final placement = _getExternalPlacement();
    final externalAdAsync = ref.watch(externalAdProvider(placement));

    if (resumeNotifier.shouldSkipAdLoad()) {
      final cached = ref.read(externalAdProvider(placement)).asData?.value;
      if (cached != null && !kIsWeb && widget.adFormat != 'native') {
        return _buildMobileAd(context, cached, isTabVisible: isTabVisible);
      }
      if (_cachedExternalAdWidget != null) {
        return _cachedExternalAdWidget!;
      }
      return const SizedBox.shrink();
    }

    return externalAdAsync.when(
      data: (externalAd) {
        if (externalAd != null) {
          _cancelRetryTimer();

          // Return the IDENTICAL cached widget when the ad hasn't changed.
          // The parent (home/matches/chats/...) rebuilds often (focus
          // changes, realtime events); handing back the same instance means
          // Flutter keeps the existing element — no remount, no impression
          // re-fire, no layout jump. Only build a fresh tree when the unit
          // id actually changes.
          if (_cachedExternalAdWidget != null &&
              _cachedExternalAdUnitId == externalAd.adUnitId) {
            return _cachedExternalAdWidget!;
          }

          final Widget newWidget;
          if (!kIsWeb && widget.adFormat != 'native') {
            newWidget = _buildMobileAd(
              context,
              externalAd,
              isTabVisible: isTabVisible,
            );
          } else if (kIsWeb) {
            newWidget = _buildWebAd(context, externalAd);
          } else {
            newWidget = _buildMobileAd(
              context,
              externalAd,
              isTabVisible: isTabVisible,
            );
          }

          // Only cache when the tab is visible so the fallback used during
          // loading/error always has isTabVisible=true.  When offstage we
          // build and return a fresh widget but never overwrite the cache.
          if (isTabVisible) {
            _cachedExternalAdWidget = KeyedSubtree(
              key: ValueKey('ext_${widget.placement}_${externalAd.adUnitId}'),
              child: newWidget,
            );
            _cachedExternalAdUnitId = externalAd.adUnitId;
          }

          return newWidget;
        }

        // External ad not available — start retry timer if online
        _startRetryTimer(placement);

        // Preserve the last good cached widget instead of clearing it.
        // This prevents blank-ad flash during the brief re-fetch window
        // after going back online.
        return _cachedExternalAdWidget ?? const SizedBox.shrink();
      },
      loading: () => _cachedExternalAdWidget ?? const SizedBox.shrink(),
      error: (error, _) {
        _startRetryTimer(placement);
        return _cachedExternalAdWidget ?? const SizedBox.shrink();
      },
    );
  }

  /// Build mobile ad widget based on format
  Widget _buildMobileAd(
    BuildContext context,
    dynamic externalAd, {
    required bool isTabVisible,
  }) {
    Widget adWidget;
    if (widget.adFormat == 'native') {
      adWidget = NativeAdWidget(
        placement: _getExternalPlacement(),
        adUnitId: externalAd.adUnitId,
        templateType: widget.embedded ? 'small' : 'medium',
      );
    } else {
      // Default to banner - fixed size for AdMob compliance
      adWidget = BannerAdWidget(
        key: _bannerAdWidgetKey,
        placement: _getExternalPlacement(),
        adUnitId: externalAd.adUnitId,
        width: widget.embedded ? 300 : 320,
        height: widget.embedded ? 40 : 50,
        onAdLoaded: () {
          // Ad loaded successfully
        },
        onAdFailed: (error) {
          // Ad failed to load
        },
      );
    }

    return Padding(
      padding: widget.embedded
          ? const EdgeInsets.fromLTRB(12, 4, 12, 4)
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: adWidget,
    );
  }

  /// Build web ad widget based on format
  Widget _buildWebAd(BuildContext context, AdUnit externalAd) {
    final placementKey = _getExternalPlacement();
    final adWidget = switch (widget.adFormat) {
      'display' => WebDisplayAdWidget(
        key: ValueKey('web_${placementKey}_${externalAd.adUnitId}'),
        placement: placementKey,
        adUnit: externalAd,
        width: widget.embedded ? 300 : 728,
        height: widget.embedded ? 250 : 90,
        responsive: true,
      ),
      'in_feed' => WebInFeedAdWidget(
        key: ValueKey('web_${placementKey}_${externalAd.adUnitId}'),
        placement: placementKey,
        adUnit: externalAd,
        width: 100,
        height: 100,
        responsive: true,
      ),
      'article' => WebArticleAdWidget(
        key: ValueKey('web_${placementKey}_${externalAd.adUnitId}'),
        placement: placementKey,
        adUnit: externalAd,
        width: widget.embedded ? 160 : 300,
        height: widget.embedded ? 600 : 600,
        responsive: true,
      ),
      'banner' || _ => WebBannerAdWidget(
        key: ValueKey('web_${placementKey}_${externalAd.adUnitId}'),
        placement: placementKey,
        adUnit: externalAd,
        width: widget.embedded ? 300 : 728,
        height: widget.embedded ? 90 : 90,
        responsive: true,
      ),
    };

    // Wrap with padding to match internal ad width
    return Padding(
      padding: widget.embedded
          ? const EdgeInsets.fromLTRB(12, 8, 12, 8)
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: adWidget,
    );
  }

  Widget _buildSponsoredAd(BuildContext context) {
    // Watch the resume provider so widget rebuilds when resume state changes
    ref.watch(appResumeNotifierProvider);
    final resumeNotifier = ref.read(appResumeNotifierProvider.notifier);
    if (resumeNotifier.shouldSkipAdLoad()) {
      // Return cached ad widget if available, otherwise show nothing
      if (_cachedSponsoredAdWidget != null) {
        return _cachedSponsoredAdWidget!;
      }
      return const SizedBox.shrink();
    }

    final sponsoredAdAsync = ref.watch(sponsoredAdProvider(widget.placement));

    return sponsoredAdAsync.when(
      data: (ad) {
        if (ad == null) {
          _startSponsoredRetryTimer(widget.placement);
          // Preserve last non-null cached widget while provider is re-fetching
          // (e.g. during the brief online re-fetch window after going offline).
          // Only clear the cache if there was never a valid ad to show.
          return _cachedSponsoredAdWidget ?? const SizedBox.shrink();
        }
        _cancelSponsoredRetryTimer();
        // Same ad as cached → return the IDENTICAL widget instance so parent
        // rebuilds (focus changes, realtime events) don't remount the card.
        if (_cachedSponsoredAdWidget != null &&
            _cachedSponsoredCreativeId == ad.creativeId) {
          return _cachedSponsoredAdWidget!;
        }
        // Cache the sponsored ad widget
        _cachedSponsoredAdWidget = Center(
          child: SponsoredCard(
            key: ValueKey('sponsored_${widget.placement}_${ad.creativeId}'),
            ad: ad,
            margin: widget.embedded
                ? const EdgeInsets.fromLTRB(12, 4, 12, 4)
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          ),
        );
        _cachedSponsoredCreativeId = ad.creativeId;
        return _cachedSponsoredAdWidget!;
      },
      loading: () {
        return _cachedSponsoredAdWidget ?? const SizedBox.shrink();
      },
      error: (error, stack) {
        _startSponsoredRetryTimer(widget.placement);
        return _cachedSponsoredAdWidget ?? const SizedBox.shrink();
      },
    );
  }

  @override
  void dispose() {
    _cancelRetryTimer();
    _cancelSponsoredRetryTimer();
    _supabaseResumeDispose?.call();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
