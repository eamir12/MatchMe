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

  /// Placement that currently owns the single in-flight banner load, or null
  /// when no load is running. Tracked per placement so [disposePlacement] can
  /// release the slot again — a bare bool would stay true forever after a
  /// placement was disposed mid-load and block every later load.
  static String? loadInFlightFor;

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
    if (loadInFlightFor == placement) loadInFlightFor = null;
    try {
      e?.ad?.dispose();
    } catch (_) {}
  }

  static void resetAll() {
    for (final placement in _entries.keys.toList()) {
      disposePlacement(placement);
    }
    loadInFlightFor = null;
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
  static const int _maxBusySpins = 20;
  int _busySpins = 0;
  static const int _loadTimeoutSeconds = 30;

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
    _busySpins = 0;
    BannerAdWidget.resetStaticState();
    _restoreFromCacheOrScheduleLoad();
  }

  void _restoreFromCacheOrScheduleLoad() {
    // The coordinator keeps the placement's last live [BannerAd]; [AdSlot]
    // re-mounts this widget on tab revisits and unit-id changes. The scheduled
    // load first ADOPTS a still-valid cached ad (validated below) and only
    // falls back to a fresh native load when the cache is dead or missing.
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
      _busySpins = 0;
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

    // Another load owns the slot — wait shortly and retry (capped). The cap
    // exists because a wedged load elsewhere used to spin this loop forever;
    // the _beginLoad timeout below now guarantees the slot is released.
    if (_entry.loading || _MobileBannerCoordinator.loadInFlightFor != null) {
      _busySpins++;
      if (_busySpins > _maxBusySpins) {
        _busySpins = 0;
        return;
      }
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted && !_isDisposed && !_isAdLoaded) _loadBannerAd();
      });
      return;
    }

    // A previous load for this placement may still be alive: the Dart-side id
    // only disappears when the ad is disposed. [getPlatformAdSize] proves the
    // native side still holds the ad (null ⇔ load() never landed or the ad was
    // disposed), so adopting it can never insert a dead ad into an [AdWidget]
    // — the plugin throws 'AdWidget requires Ad.load...' for those.
    final cached = _MobileBannerCoordinator.cachedAd(
      widget.placement,
      adUnitId,
      widget.width,
      widget.height,
    );
    if (cached != null) {
      cached.getPlatformAdSize().then(
        (size) {
          final stillCached = _MobileBannerCoordinator.cachedAd(
            widget.placement,
            adUnitId,
            widget.width,
            widget.height,
          );
          if (!mounted || _isDisposed || _isAdLoaded) return;
          if (size != null && stillCached == cached) {
            _MobileBannerCoordinator.storeLoaded(
              widget.placement,
              cached,
              adUnitId,
              widget.width,
              widget.height,
            );
            setState(() {
              _bannerAd = cached;
              _isAdLoaded = true;
            });
          } else {
            _loadBannerAd();
          }
        },
        onError: (Object _) {
          if (!mounted || _isDisposed || _isAdLoaded) return;
          _loadBannerAd();
        },
      );
      return;
    }

    _beginLoad(adUnitId, placementKey);
  }

  void _beginLoad(String adUnitId, String placementKey) {
    _busySpins = 0;
    _entry.loading = true;
    _MobileBannerCoordinator.loadInFlightFor = widget.placement;
    final int currentAttempt = ++_loadAttemptId;

    final bannerAd = BannerAd(
      adUnitId: adUnitId,
      size: AdSize(width: widget.width, height: widget.height),
      // No 'test' keywords: this is a real ad request in production builds.
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          _entry.loading = false;
          if (_MobileBannerCoordinator.loadInFlightFor == widget.placement) {
            _MobileBannerCoordinator.loadInFlightFor = null;
          }
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
          if (_MobileBannerCoordinator.loadInFlightFor == widget.placement) {
            _MobileBannerCoordinator.loadInFlightFor = null;
          }
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
      if (_MobileBannerCoordinator.loadInFlightFor == widget.placement) {
        _MobileBannerCoordinator.loadInFlightFor = null;
      }
      try {
        bannerAd.dispose();
      } catch (_) {}
      return;
    }

    try {
      unawaited(
        bannerAd
            .load()
            .timeout(const Duration(seconds: _loadTimeoutSeconds))
            .then<void>(
              (_) {},
              onError: (Object _) {
                // The native handler can throw before ever replying — e.g. the
                // platform channel already tracked this adId after a Dart hot
                // restart ('Ad for following adId already exists: 0'). In that
                // case the load() future never completes and nothing below the
                // timeout runs a second time, so release the load slot, void the
                // attempt (late listener events then dispose their ad instead of
                // adopting it) and drop the half-registered ad.
                if (_MobileBannerCoordinator.loadInFlightFor ==
                    widget.placement) {
                  _MobileBannerCoordinator.loadInFlightFor = null;
                }
                if (_entry.loading) _entry.loading = false;
                ++_loadAttemptId;
                try {
                  bannerAd.dispose();
                } catch (_) {}
              },
            ),
      );
    } catch (e) {
      _entry.loading = false;
      if (_MobileBannerCoordinator.loadInFlightFor == widget.placement) {
        _MobileBannerCoordinator.loadInFlightFor = null;
      }
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
