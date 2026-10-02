import 'package:matchme/services/ad_platform_support.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/services/external_ad_service.dart';

/// Widget for displaying interstitial ads
///
/// This widget:
/// - Fetches ad for placement
/// - Loads the ad
/// - Provides method to show ad
/// - Tracks impressions and clicks
class InterstitialAdWidget extends ConsumerStatefulWidget {
  const InterstitialAdWidget({
    super.key,
    required this.placement,
    this.onAdLoaded,
    this.onAdFailed,
    this.onAdDismissed,
  });

  final String placement;
  final VoidCallback? onAdLoaded;
  final Function(String error)? onAdFailed;
  final VoidCallback? onAdDismissed;

  @override
  ConsumerState<InterstitialAdWidget> createState() =>
      _InterstitialAdWidgetState();
}

class _InterstitialAdWidgetState extends ConsumerState<InterstitialAdWidget> {
  AdUnit? _currentAd;

  @override
  void initState() {
    super.initState();
    _loadAd();
  }

  Future<void> _loadAd() async {
    try {
      final mediationService = ref.read(adMediationServiceProvider);
      final ad = await mediationService.getBestAdForPlacement(
        placement: widget.placement,
        platform: _getPlatform(),
      );

      if (ad != null && mounted) {
        setState(() {
          _currentAd = ad;
        });
        widget.onAdLoaded?.call();
      } else if (mounted) {
        widget.onAdFailed?.call('No ad available');
      }
    } catch (e) {
      if (mounted) {
        widget.onAdFailed?.call(e.toString());
      }
    }
  }

  Future<void> showAd() async {
    if (_currentAd == null) {
      widget.onAdFailed?.call('Ad not loaded');
      return;
    }

    try {
      // Track impression
      final mediationService = ref.read(adMediationServiceProvider);
      await mediationService.recordImpressionForAd(_currentAd!);

      // TODO: Show interstitial ad using google_mobile_ads
      // await _interstitialAd?.show();

      // Simulate ad shown
      if (mounted) {
        widget.onAdDismissed?.call();
      }

      // Reload ad for next time
      _loadAd();
    } catch (e) {
      widget.onAdFailed?.call(e.toString());
    }
  }

  String _getPlatform() {
    return adPlatformKey();
  }

  @override
  Widget build(BuildContext context) {
    // This widget doesn't render anything visible
    // It's used to manage ad loading and display
    return const SizedBox.shrink();
  }
}
