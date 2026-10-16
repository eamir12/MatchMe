import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/services/external_ad_service.dart';
import 'package:matchme/providers/locale_provider.dart';

/// Widget for displaying web article ads (300x600, 160x600, etc.)
///
/// Article ads are tall, narrow ads designed to appear alongside article content.
/// They're commonly used in news and content-heavy websites.
///
/// This widget:
/// - Displays clickable article ads
/// - Tracks impressions and clicks
/// - Handles errors gracefully
class WebArticleAdWidget extends ConsumerStatefulWidget {
  const WebArticleAdWidget({
    super.key,
    required this.placement,
    required this.adUnit,
    this.width = 300,
    this.height = 600,
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
  ConsumerState<WebArticleAdWidget> createState() => _WebArticleAdWidgetState();
}

class _WebArticleAdWidgetState extends ConsumerState<WebArticleAdWidget> {
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
              // Top image area
              Container(
                width: double.infinity,
                height: widget.height * 0.45,
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.diamond,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                      size: 40,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.getString('webAdDiamond'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              // Content
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.getString('webAdGoPremium'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.getString('webAdUnlockExclusive'),
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 12,
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.visible,
                          ),
                        ],
                      ),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Center(
                          child: Text(
                            l10n.getString('webAdUpgradeNow'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
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
    if (_didTrackImpression || _isDisposed) return;
    _didTrackImpression = true;
    try {
      final mediationService = ref.read(adMediationServiceProvider);
      mediationService.recordImpressionForAd(widget.adUnit);
      print('[WebArticleAd] Impression tracked');
    } catch (e) {
      print('[WebArticleAd] Failed to track impression: $e');
    }
  }

  Future<void> _handleAdClick() async {
    if (_isDisposed) return;
    try {
      final mediationService = ref.read(adMediationServiceProvider);
      mediationService.recordClickForAd(widget.adUnit);
      print('[WebArticleAd] Click tracked');
    } catch (e) {
      print('[WebArticleAd] Failed to track click: $e');
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

/// Placeholder web article ad widget (for testing without google_adsense)
class PlaceholderWebArticleAd extends ConsumerWidget {
  const PlaceholderWebArticleAd({
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
              Icons.article,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              size: 56,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.getString('webArticleAdPlaceholder'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
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
