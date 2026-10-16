import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/services/external_ad_service.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/theme/app_theme_tokens.dart';

/// Widget for displaying web in-feed ads
///
/// In-feed ads are designed to blend with content feeds and appear
/// between content items. They typically have flexible dimensions.
///
/// This widget:
/// - Displays clickable in-feed ads
/// - Tracks impressions and clicks
/// - Handles errors gracefully
class WebInFeedAdWidget extends ConsumerStatefulWidget {
  const WebInFeedAdWidget({
    super.key,
    required this.placement,
    required this.adUnit,
    this.width = 100,
    this.height = 100,
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
  ConsumerState<WebInFeedAdWidget> createState() => _WebInFeedAdWidgetState();
}

class _WebInFeedAdWidgetState extends ConsumerState<WebInFeedAdWidget> {
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sponsoredBackground = isDark
        ? AppThemeTokens.darkTertiary
        : const Color(0xFF92400E);
    final sponsoredForeground = isDark
        ? AppThemeTokens.darkOnTertiary
        : Colors.white;

    return Container(
      width: widget.responsive ? double.infinity : widget.width.toDouble(),
      height: widget.height.toDouble(),
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _handleAdClick,
          borderRadius: BorderRadius.circular(8),
          child: Row(
            children: [
              // Square image on left
              Container(
                width: widget.height.toDouble(),
                height: widget.height.toDouble(),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(8),
                    bottomLeft: Radius.circular(8),
                  ),
                ),
                child: Icon(
                  Icons.star,
                  color: Theme.of(context).colorScheme.onTertiaryContainer,
                  size: 32,
                ),
              ),
              // Content
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: sponsoredBackground,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text(
                          l10n.getString('webAdSponsored'),
                          style: TextStyle(
                            color: sponsoredForeground,
                            fontSize: 9,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.getString('webAdUpgradeExperience'),
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
                        l10n.getString('webAdGetUnlimitedMatches'),
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                          fontSize: 11,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.visible,
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
      print('[WebInFeedAd] Impression tracked');
    } catch (e) {
      print('[WebInFeedAd] Failed to track impression: $e');
    }
  }

  Future<void> _handleAdClick() async {
    if (_isDisposed) return;
    try {
      final mediationService = ref.read(adMediationServiceProvider);
      mediationService.recordClickForAd(widget.adUnit);
      print('[WebInFeedAd] Click tracked');
    } catch (e) {
      print('[WebInFeedAd] Failed to track click: $e');
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

/// Placeholder web in-feed ad widget (for testing without google_adsense)
class PlaceholderWebInFeedAd extends ConsumerWidget {
  const PlaceholderWebInFeedAd({
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
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.feed,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.getString('webInFeedAdPlaceholder'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
