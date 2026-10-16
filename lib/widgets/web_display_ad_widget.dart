import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/services/external_ad_service.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/theme/semantic_colors.dart';

/// Widget for displaying web display ads (300x250, 728x90, etc.)
///
/// This widget:
/// - Displays clickable web display ads
/// - Tracks impressions and clicks
/// - Handles errors gracefully
class WebDisplayAdWidget extends ConsumerStatefulWidget {
  const WebDisplayAdWidget({
    super.key,
    required this.placement,
    required this.adUnit,
    this.width = 300,
    this.height = 250,
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
  ConsumerState<WebDisplayAdWidget> createState() => _WebDisplayAdWidgetState();
}

class _WebDisplayAdWidgetState extends ConsumerState<WebDisplayAdWidget> {
  bool _didTrackImpression = false;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isDisposed) _trackImpressionOnce();
    });
  }

  @override
  Widget build(BuildContext context) {
    widget.onAdLoaded?.call();

    final l10n = ref.watch(localizationProvider);
    final semantic = SemanticColors.of(context);

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
          child: Column(
            children: [
              // Large ad image area
              Expanded(
                child: Container(
                  width: double.infinity,
                  color: semantic.successContainer,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.image, color: semantic.success, size: 48),
                      const SizedBox(height: 8),
                      Text(
                        l10n.getString('webAdSpecialOffer'),
                        style: TextStyle(
                          color: semantic.onSuccessContainer,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.getString('webAdPremiumOffer'),
                        style: TextStyle(
                          color: semantic.success,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // CTA button at bottom
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: semantic.success,
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(4),
                    bottomRight: Radius.circular(4),
                  ),
                ),
                child: Center(
                  child: Text(
                    l10n.getString('webAdGetOffer'),
                    style: TextStyle(
                      color: semantic.onSuccess,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
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
    if (_didTrackImpression || _isDisposed) return;
    _didTrackImpression = true;
    try {
      final mediationService = ref.read(adMediationServiceProvider);
      mediationService.recordImpressionForAd(widget.adUnit);
      print('[WebDisplayAd] Impression tracked');
    } catch (e) {
      print('[WebDisplayAd] Failed to track impression: $e');
    }
  }

  Future<void> _handleAdClick() async {
    if (_isDisposed) return;
    try {
      final mediationService = ref.read(adMediationServiceProvider);
      mediationService.recordClickForAd(widget.adUnit);
      print('[WebDisplayAd] Click tracked');
    } catch (e) {
      print('[WebDisplayAd] Failed to track click: $e');
    }
    final uri = Uri.parse('https://ads.google.com');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}

/// Placeholder web display ad widget (for testing without google_adsense)
class PlaceholderWebDisplayAd extends ConsumerWidget {
  const PlaceholderWebDisplayAd({
    super.key,
    required this.width,
    required this.height,
    required this.responsive,
  });

  final int width;
  final int height;
  final bool responsive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    return Container(
      width: responsive ? double.infinity : width.toDouble(),
      height: height.toDouble(),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.image,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.getString('webDisplayAdPlaceholder'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$width x $height',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
