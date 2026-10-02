import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/providers/home_providers.dart';

/// Widget for displaying native ads using Google Mobile Ads SDK
///
/// This widget:
/// - Fetches ad unit ID from database
/// - Loads the native ad from Google Mobile Ads
/// - Displays ad in native format
/// - Tracks impressions and clicks
class NativeAdWidget extends ConsumerStatefulWidget {
  const NativeAdWidget({
    super.key,
    required this.placement,
    this.adUnitId,
    this.templateType = 'medium',
    this.onAdLoaded,
    this.onAdFailed,
  });

  final String placement;
  final String? adUnitId;
  final String templateType; // 'small', 'medium', 'large'
  final VoidCallback? onAdLoaded;
  final Function(String error)? onAdFailed;

  @override
  ConsumerState<NativeAdWidget> createState() => _NativeAdWidgetState();
}

class _NativeAdWidgetState extends ConsumerState<NativeAdWidget>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  NativeAd? _nativeAd;
  bool _isAdLoaded = false;
  bool _didTrackImpression = false;
  bool _isDisposed = false;
  bool _isDisposing = false;
  bool _wasPaused =
      false; // Track if app was paused (backgrounded or screen off)

  bool get _isScreenVisible {
    final currentIndex = ref.watch(navigationIndexProvider);
    return switch (widget.placement) {
      'home_inline' => currentIndex == 0,
      'matches_inline' => currentIndex == 1,
      'chats_inline' => currentIndex == 2,
      'events_inline' => currentIndex == 3,
      'profile_inline' => currentIndex == 4,
      _ => true,
    };
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadNativeAd();
  }

  @override
  void didUpdateWidget(covariant NativeAdWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldReload =
        oldWidget.placement != widget.placement ||
        oldWidget.adUnitId != widget.adUnitId ||
        oldWidget.templateType != widget.templateType;

    if (shouldReload) {
      _didTrackImpression = false;
      _disposeNativeAd();
      _loadNativeAd();
    }
    // Track impression when screen becomes visible and ad is already loaded
    // This will trigger when navigationIndexProvider updates
    if (_isScreenVisible && _isAdLoaded && !_didTrackImpression) {
      _trackImpressionOnce();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // App was backgrounded or screen turned off
      _wasPaused = true;
    } else if (state == AppLifecycleState.resumed && _wasPaused) {
      // App resumed from paused state - don't reload, ad stays in memory
      _wasPaused = false;
    }
    // Don't reload ads when app resumes - only reload if config actually changes
    // The ad will continue to display from memory
  }

  void _loadNativeAd() {
    // Don't load if widget is disposed or being disposed
    if (_isDisposed || _isDisposing || !mounted) {
      return;
    }

    // Use provided ad unit ID or fall back to test ID
    final adUnitId =
        widget.adUnitId ?? 'ca-app-pub-3940256099942544/2247696110';

    final nativeAd = NativeAd(
      adUnitId: adUnitId,
      factoryId: 'listTile',
      request: const AdRequest(keywords: ['test']),
      listener: NativeAdListener(
        onAdLoaded: (ad) {
          if (!mounted || _isDisposed || _isDisposing) {
            // Dispose the ad if widget is no longer valid
            try {
              ad.dispose();
            } catch (_) {}
            return;
          }
          if (mounted && !_isDisposed) {
            setState(() {
              _isAdLoaded = true;
            });
          }
          widget.onAdLoaded?.call();
          // Note: Impression tracking moved to onAdImpression for accuracy
        },
        onAdFailedToLoad: (ad, error) {
          // Always dispose the ad that failed to load
          try {
            ad.dispose();
          } catch (_) {}
          if (!mounted || _isDisposed || _isDisposing) return;
          widget.onAdFailed?.call(error.message);
        },
        onAdOpened: (ad) {
          if (_isDisposed || _isDisposing) return;
        },
        onAdClosed: (ad) {
          if (_isDisposed || _isDisposing) return;
        },
        onAdImpression: (ad) {
          if (_isDisposed || _isDisposing) return;
          // Only track impression if screen is visible
          if (_isScreenVisible && mounted) {
            _trackImpressionOnce();
          }
        },
        onAdClicked: (ad) {
          if (_isDisposed || _isDisposing) return;
          _trackClick();
        },
      ),
    );

    // Don't load if widget became disposed during setup
    if (_isDisposed || _isDisposing || !mounted) {
      try {
        nativeAd.dispose();
      } catch (_) {}
      return;
    }

    nativeAd.load();

    if (mounted && !_isDisposed) {
      setState(() {
        _nativeAd = nativeAd;
      });
    }
  }

  void _disposeNativeAd() {
    if (_isDisposing || _isDisposed) return;
    _isDisposing = true;

    try {
      _nativeAd?.dispose();
    } catch (e) {
      // Ignore disposal errors - ad may already be disposed
    }
    _nativeAd = null;
    _isAdLoaded = false;
    _isDisposing = false;
  }

  void _trackImpressionOnce() {
    if (_didTrackImpression || _isDisposed || _isDisposing) {
      return;
    }
    _didTrackImpression = true;

    // Track impression via mediation service
    try {
      final mediationService = ref.read(adMediationServiceProvider);
      ref.read(externalAdProvider(widget.placement)).whenData((ad) {
        if (ad != null && mounted && !_isDisposed) {
          mediationService.recordImpressionForAd(ad);
        }
      });
    } catch (e) {
      // Silently ignore impression tracking errors
    }
  }

  void _trackClick() {
    if (_isDisposed || _isDisposing) return;

    // Track click via mediation service
    try {
      final mediationService = ref.read(adMediationServiceProvider);
      ref.read(externalAdProvider(widget.placement)).whenData((ad) {
        if (ad != null && mounted && !_isDisposed) {
          mediationService.recordClickForAd(ad);
        }
      });
    } catch (e) {
      // Silently ignore click tracking errors
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _disposeNativeAd();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Listen to navigation changes to record impressions when navigating to this screen
    ref.listen<int>(navigationIndexProvider, (previous, next) {
      if (_isScreenVisible && _isAdLoaded && !_didTrackImpression) {
        _trackImpressionOnce();
      }
    });

    if (_nativeAd == null || !_isAdLoaded) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      height: _getTemplateHeight(),
      child: AdWidget(ad: _nativeAd!),
    );
  }

  double _getTemplateHeight() {
    switch (widget.templateType) {
      case 'small':
        return 80;
      case 'large':
        return 400;
      case 'medium':
      default:
        return 250;
    }
  }
}
