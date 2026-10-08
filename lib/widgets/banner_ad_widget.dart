import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/services/ad_platform_support.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Per-placement [BannerAd] cache. Each tab keeps its own ad; [AdWidget] stays in
/// an [Offstage] parent ([AdSlot]) so revisiting a tab shows instantly.
class _PlacementBannerEntry {
  BannerAd? ad;
  String? adUnitId;
  int? width;
  int? height;
  bool loading = false;
}

class _MobileBannerCoordinator {
  static final Map<String, _PlacementBannerEntry> _entries = {};
  static bool loadInFlight = false;

  static _PlacementBannerEntry entryFor(String placement) =>
      _entries.putIfAbsent(placement, () => _PlacementBannerEntry());

  static BannerAd? cachedAd(
    String placement,
    String adUnitId,
    int width,
    int height,
  ) {
    final e = _entries[placement];
    if (e == null || e.ad == null) return null;
    if (e.adUnitId == adUnitId && e.width == width && e.height == height) {
      return e.ad;
    }
    return null;
  }

  static void storeLoaded(
    String placement,
    BannerAd ad,
    String adUnitId,
    int width,
    int height,
  ) {
    final e = entryFor(placement);
    e.ad = ad;
    e.adUnitId = adUnitId;
    e.width = width;
    e.height = height;
    e.loading = false;
  }

  static void disposePlacement(String placement) {
    final e = _entries.remove(placement);
    e?.loading = false;
    try {
      e?.ad?.dispose();
    } catch (_) {}
  }

  static void resetAll() {
    for (final placement in _entries.keys.toList()) {
      disposePlacement(placement);
    }
    loadInFlight = false;
  }
}

/// Widget for displaying banner ads using Google Mobile Ads SDK.
class BannerAdWidget extends ConsumerStatefulWidget {
  const BannerAdWidget({
    super.key,
    required this.placement,
    this.adUnitId,
    this.width = 320,
    this.height = 50,
    this.onAdLoaded,
    this.onAdFailed,
  });

  final String placement;
  final String? adUnitId;
  final int width;
  final int height;
  final VoidCallback? onAdLoaded;
  final Function(String error)? onAdFailed;

  static bool _adServiceUnavailable = false;
  static final Set<String> _failedPlacements = {};

  static void resetStaticState() {
    _MobileBannerCoordinator.resetAll();
    _adServiceUnavailable = false;
    _failedPlacements.clear();
  }

  @override
  ConsumerState<BannerAdWidget> createState() => _BannerAdWidgetState();
}

class _BannerAdWidgetState extends ConsumerState<BannerAdWidget>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  BannerAd? _bannerAd;
  bool _isAdLoaded = false;
  bool _didTrackImpression = false;
  int _retryCount = 0;
  bool _isDisposed = false;
  bool _isAppInForeground = true;
  bool _loadScheduled = false;

  static const int _maxRetries = 3;
  int _loadAttemptId = 0;

  _PlacementBannerEntry get _entry =>
      _MobileBannerCoordinator.entryFor(widget.placement);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreFromCacheOrScheduleLoad();
  }

  @override
  void reassemble() {
    super.reassemble();
    _bannerAd = null;
    _isAdLoaded = false;
    _didTrackImpression = false;
    _loadScheduled = false;
    BannerAdWidget.resetStaticState();
    _restoreFromCacheOrScheduleLoad();
  }

  void _restoreFromCacheOrScheduleLoad() {
    // Always schedule a fresh load — the cached native ad may have been
    // invalidated, so we must not reuse it directly in an AdWidget.
    // The coordinator still deduplicates simultaneous loads.
    _scheduleLoad();
  }

  @override
  void didUpdateWidget(covariant BannerAdWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldReload =
        oldWidget.placement != widget.placement ||
        oldWidget.adUnitId != widget.adUnitId ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height;

    if (shouldReload) {
      _didTrackImpression = false;
      _retryCount = 0;
      _loadScheduled = false;
      if (oldWidget.placement != widget.placement) {
        // Placement key change only — old placement cache is kept for revisit.
      } else {
        _MobileBannerCoordinator.disposePlacement(widget.placement);
      }
      _bannerAd = null;
      _isAdLoaded = false;
      _scheduleLoad();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _isAppInForeground = false;
    } else if (state == AppLifecycleState.resumed) {
      _isAppInForeground = true;
    }
  }

  void _scheduleLoad() {
    if (_loadScheduled || _isDisposed || _isAdLoaded) return;

    final placementKey = '${widget.placement}_${widget.adUnitId}';
    if (BannerAdWidget._failedPlacements.contains(placementKey) ||
        BannerAdWidget._adServiceUnavailable) {
      return;
    }

    _loadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadScheduled = false;
      if (!mounted || _isDisposed || _isAdLoaded) return;
      _loadBannerAd();
    });
  }

  String? _resolvedAdUnitId() {
    if (widget.adUnitId != null && widget.adUnitId!.trim().isNotEmpty) {
      return widget.adUnitId;
    }
    // Google's public sample unit may only be used in debug builds — serving
    // it to real users generates invalid-traffic risk for the AdMob account.
    return kDebugMode ? 'ca-app-pub-3940256099942544/6300978111' : null;
  }

  void _loadBannerAd() {
    if (_isDisposed || !mounted) return;
    if (BannerAdWidget._adServiceUnavailable) return;
    // google_mobile_ads has no Windows/macOS/Linux implementation, so the
    // plugin is not registered there and every BannerAd.load() fails. Detect it
    // up front rather than converting a guaranteed MissingPluginException into
    // a silent "ad service unavailable" flag at runtime.
    if (!isAdRenderSupported) {
      logAdPlatformSupportOnce();
      return;
    }

    final placementKey = '${widget.placement}_${widget.adUnitId}';
    if (BannerAdWidget._failedPlacements.contains(placementKey)) return;

    final adUnitId = _resolvedAdUnitId();
    if (adUnitId == null) {
      if (kDebugMode) {
        print(
          '[BannerAdWidget] ${widget.placement}: no ad unit id configured; '
          'debug fallback disabled in release builds',
        );
      }
      return;
    }

    if (_entry.loading || _MobileBannerCoordinator.loadInFlight) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted && !_isDisposed && !_isAdLoaded) _loadBannerAd();
      });
      return;
    }

    _entry.loading = true;
    _MobileBannerCoordinator.loadInFlight = true;
    final int currentAttempt = ++_loadAttemptId;

    final bannerAd = BannerAd(
      adUnitId: adUnitId,
      size: AdSize(width: widget.width, height: widget.height),
      // No 'test' keywords: this is a real ad request in production builds.
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          _entry.loading = false;
          _MobileBannerCoordinator.loadInFlight = false;
          if (currentAttempt != _loadAttemptId) {
            try {
              ad.dispose();
            } catch (_) {}
            return;
          }
          if (!mounted || _isDisposed) {
            try {
              ad.dispose();
            } catch (_) {}
            return;
          }

          final loaded = ad as BannerAd;
          _MobileBannerCoordinator.storeLoaded(
            widget.placement,
            loaded,
            adUnitId,
            widget.width,
            widget.height,
          );
          _retryCount = 0;
          setState(() {
            _bannerAd = loaded;
            _isAdLoaded = true;
          });
          widget.onAdLoaded?.call();
        },
        onAdFailedToLoad: (ad, error) {
          _entry.loading = false;
          _MobileBannerCoordinator.loadInFlight = false;
          try {
            ad.dispose();
          } catch (_) {}
          if (!mounted || _isDisposed) return;

          final errorCode = error.code;
          widget.onAdFailed?.call(
            _getErrorDescription(errorCode, error.message),
          );

          if (errorCode == 0) {
            BannerAdWidget._adServiceUnavailable = true;
            BannerAdWidget._failedPlacements.add(placementKey);
            setState(() {});
            return;
          }

          if (_shouldRetry(errorCode) && _retryCount < _maxRetries) {
            _retryCount++;
            Future.delayed(Duration(seconds: _retryCount * 2), () {
              if (mounted) _loadBannerAd();
            });
          } else {
            BannerAdWidget._failedPlacements.add(placementKey);
            setState(() {});
          }
        },
        onAdClicked: (ad) {
          if (!_isDisposed) _trackClick();
        },
      ),
    );

    if (_isDisposed || !mounted) {
      _entry.loading = false;
      _MobileBannerCoordinator.loadInFlight = false;
      try {
        bannerAd.dispose();
      } catch (_) {}
      return;
    }

    try {
      unawaited(
        bannerAd.load().catchError((Object _) {
          _entry.loading = false;
          _MobileBannerCoordinator.loadInFlight = false;
          try {
            bannerAd.dispose();
          } catch (_) {}
        }),
      );
    } catch (e) {
      _entry.loading = false;
      _MobileBannerCoordinator.loadInFlight = false;
      try {
        bannerAd.dispose();
      } catch (_) {}
    }
  }

  void _trackImpressionOnce() {
    if (_didTrackImpression || _isDisposed) return;
    _didTrackImpression = true;
    try {
      final mediationService = ref.read(adMediationServiceProvider);
      ref.read(externalAdProvider(widget.placement)).whenData((ad) {
        if (ad != null && mounted && !_isDisposed) {
          mediationService.recordImpressionForAd(ad);
        }
      });
    } catch (_) {}
  }

  void _trackClick() {
    if (_isDisposed) return;
    try {
      final mediationService = ref.read(adMediationServiceProvider);
      ref.read(externalAdProvider(widget.placement)).whenData((ad) {
        if (ad != null && mounted && !_isDisposed) {
          mediationService.recordClickForAd(ad);
        }
      });
    } catch (_) {}
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (!_didTrackImpression &&
        _isAppInForeground &&
        info.visibleFraction >= 0.5) {
      _didTrackImpression = true;
      _trackImpressionOnce();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    // Keep [BannerAd] in coordinator — [AdSlot] retains this widget in [Offstage].
    _bannerAd = null;
    _isAdLoaded = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_bannerAd == null || !_isAdLoaded) {
      _scheduleLoad();
      return const SizedBox.shrink();
    }

    final cached = _MobileBannerCoordinator.cachedAd(
      widget.placement,
      _resolvedAdUnitId() ?? '',
      widget.width,
      widget.height,
    );
    if (cached != _bannerAd) {
      _bannerAd = null;
      _isAdLoaded = false;
      _scheduleLoad();
      return const SizedBox.shrink();
    }

    return VisibilityDetector(
      key: ValueKey('visibility_${widget.placement}_${widget.adUnitId}'),
      onVisibilityChanged: _onVisibilityChanged,
      child: SizedBox(
        width: _bannerAd!.size.width.toDouble(),
        height: _bannerAd!.size.height.toDouble(),
        child: AdWidget(ad: _bannerAd!),
      ),
    );
  }

  String _getErrorDescription(int code, String message) {
    switch (code) {
      case 0:
        return 'Internal error: $message';
      case 1:
        return 'Invalid request: $message';
      case 2:
        return 'Network error - check connection: $message';
      case 3:
        return 'No fill - AdMob has no ad to serve (normal in test/development)';
      default:
        return 'Error $code: $message';
    }
  }

  bool _shouldRetry(int errorCode) => errorCode == 2;
}
