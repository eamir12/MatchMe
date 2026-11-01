import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/services/external_ad_service.dart';
import 'package:matchme/providers/locale_provider.dart';

/// Widget for displaying web banner ads
///
/// This widget:
/// - Displays web banner ads with clickable content
/// - Tracks impressions and clicks
/// - Handles errors gracefully
class WebBannerAdWidget extends ConsumerStatefulWidget {
  const WebBannerAdWidget({
    super.key,
    required this.placement,
    required this.adUnit,
    this.width = 728,
    this.height = 90,
    this.responsive = true,
    this.onAdLoaded,
    this.onAdFailed,
  });

  final String placement;
  final AdUnit adUnit;
  final int width;
  final int height;
  final bool responsive;
  final VoidCallback? onAdLoaded;
  final Function(String error)? onAdFailed;

  @override
  ConsumerState<WebBannerAdWidget> createState() => _WebBannerAdWidgetState();
}

class _WebBannerAdWidgetState extends ConsumerState<WebBannerAdWidget> {
  bool _didTrackImpression = false;
  bool _isDisposed = false;

  /// Cross-instance dedup: parent rebuilds (window focus changes, realtime
  /// events) used to remount this widget and re-fire an impression for the
  /// same ad dozens of times within seconds (visible as log spam and backend
  /// RPC storms). Track at most once per (placement, ad unit) per minute —
  /// legitimate repeat views still count, remount storms don't.
  static final Map<String, DateTime> _lastImpressionAt = {};

  static bool _claimImpression(String key) {
    final now = DateTime.now();
    final last = _lastImpressionAt[key];
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      return false;
    }
    _lastImpressionAt[key] = now;
    // Bound memory: drop entries older than 10 minutes.
    if (_lastImpressionAt.length > 200) {
      _lastImpressionAt.removeWhere(
        (_, at) => now.difference(at) > const Duration(minutes: 10),
      );
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    // Track impression after widget builds
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isDisposed) {
        _trackImpressionOnce();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Call onAdLoaded callback
    widget.onAdLoaded?.call();

    final l10n = ref.watch(localizationProvider);

    return Container(
      width: widget.responsive ? double.infinity : widget.width.toDouble(),
      height: widget.height.toDouble(),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _handleAdClick,
          borderRadius: BorderRadius.circular(4),
          child: Row(
            children: [
              // Ad image placeholder
              Container(
                width: widget.height.toDouble(),
                height: widget.height.toDouble(),
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Icon(
                  Icons.image,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  size: 24,
                ),
              ),
              // Ad content
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        l10n.getString('webAdTryPremium'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.visible,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.getString('webAdUnlockFeatures'),
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                          fontSize: 12,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.visible,
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text(
                          l10n.getString('webAdLearnMore'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _trackImpressionOnce() {
    if (_didTrackImpression || _isDisposed) {
      return;
    }
    _didTrackImpression = true;

    // Drop remount-storm duplicates for the same ad (see _claimImpression).
    final dedupKey = '${widget.placement}|${widget.adUnit.adUnitId}';
    if (!_claimImpression(dedupKey)) {
      return;
    }

    // Track impression via mediation service
    try {
      final mediationService = ref.read(adMediationServiceProvider);
      mediationService.recordImpressionForAd(widget.adUnit);
      print('[WebBannerAd] Impression tracked for ${widget.placement}');
    } catch (e) {
      // Silently ignore impression tracking errors
      print('[WebBannerAd] Failed to track impression: $e');
    }
  }

  Future<void> _handleAdClick() async {
    if (_isDisposed) return;

    // Track click
    try {
      final mediationService = ref.read(adMediationServiceProvider);
      mediationService.recordClickForAd(widget.adUnit);
      print('[WebBannerAd] Click tracked for ${widget.placement}');
    } catch (e) {
      print('[WebBannerAd] Failed to track click: $e');
    }

    // Open ad URL (use a generic ad URL or the network's URL)
    final adUrl = _getAdUrl();
    if (adUrl != null) {
      final uri = Uri.parse(adUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }

  String? _getAdUrl() {
    // Return appropriate URL based on ad unit or network
    // For now, return a placeholder or use the ad unit ID as hint
    if (widget.adUnit.adUnitId.contains('google') ||
        widget.adUnit.adUnitId.startsWith('ca-app-pub')) {
      return 'https://ads.google.com';
    }
    return 'https://www.google.com';
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
