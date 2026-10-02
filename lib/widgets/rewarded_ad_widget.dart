import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/mobile_ad.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/services/external_ad_service.dart';
import 'package:matchme/services/ad_platform_support.dart';

/// Widget for displaying rewarded ads
///
/// This widget:
/// - Fetches ad for placement
/// - Loads the ad
/// - Provides method to show ad
/// - Tracks impressions, clicks, and completions
/// - Handles reward callbacks
class RewardedAdWidget extends ConsumerStatefulWidget {
  const RewardedAdWidget({
    super.key,
    required this.placement,
    this.onAdLoaded,
    this.onAdFailed,
    this.onAdDismissed,
    this.onRewardEarned,
  });

  final String placement;
  final VoidCallback? onAdLoaded;
  final Function(String error)? onAdFailed;
  final VoidCallback? onAdDismissed;
  final Function(AdReward reward)? onRewardEarned;

  @override
  ConsumerState<RewardedAdWidget> createState() => _RewardedAdWidgetState();
}

class _RewardedAdWidgetState extends ConsumerState<RewardedAdWidget> {
  AdUnit? _currentAd;
  bool _isLoading = false;
  bool _isShowing = false;

  @override
  void initState() {
    super.initState();
    _loadAd();
  }

  Future<void> _loadAd() async {
    setState(() => _isLoading = true);

    try {
      final mediationService = ref.read(adMediationServiceProvider);
      final ad = await mediationService.getBestAdForPlacement(
        placement: widget.placement,
        platform: _getPlatform(),
      );

      if (ad != null && mounted) {
        setState(() {
          _currentAd = ad;
          _isLoading = false;
        });
        widget.onAdLoaded?.call();
      } else if (mounted) {
        setState(() => _isLoading = false);
        widget.onAdFailed?.call('No ad available');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        widget.onAdFailed?.call(e.toString());
      }
    }
  }

  Future<void> showAd() async {
    if (_currentAd == null) {
      widget.onAdFailed?.call('Ad not loaded');
      return;
    }

    if (_isShowing) {
      widget.onAdFailed?.call('Ad already showing');
      return;
    }

    setState(() => _isShowing = true);

    try {
      // Track impression
      final mediationService = ref.read(adMediationServiceProvider);
      await mediationService.recordImpressionForAd(_currentAd!);

      // TODO: Show rewarded ad using google_mobile_ads
      // await _rewardedAd?.show(
      //   onUserEarnedReward: (ad, reward) {
      //     _handleReward(reward);
      //   },
      // );

      // Simulate reward earned
      _handleReward(const AdReward(type: 'coins', amount: 10));

      if (mounted) {
        setState(() => _isShowing = false);
        widget.onAdDismissed?.call();
      }

      // Reload ad for next time
      _loadAd();
    } catch (e) {
      if (mounted) {
        setState(() => _isShowing = false);
      }
      widget.onAdFailed?.call(e.toString());
    }
  }

  void _handleReward(AdReward reward) {
    widget.onRewardEarned?.call(reward);
  }

  String _getPlatform() {
    return adPlatformKey();
  }

  bool get isAdReady => _currentAd != null && !_isLoading;
  bool get isAdShowing => _isShowing;

  @override
  Widget build(BuildContext context) {
    // This widget doesn't render anything visible
    // It's used to manage ad loading and display
    return const SizedBox.shrink();
  }
}
