import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/sponsored_ad.dart';
import 'package:matchme/providers/ad_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:visibility_detector/visibility_detector.dart';

// Simple image viewer dialog
class _ImageViewerDialog extends StatelessWidget {
  final String imageUrl;

  const _ImageViewerDialog({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: CachedNetworkImage(
            imageUrl: imageUrl,
            fit: BoxFit.contain,
            placeholder: (context, url) =>
                const Center(child: CircularProgressIndicator()),
            errorWidget: (context, url, error) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

class SponsoredCard extends ConsumerStatefulWidget {
  const SponsoredCard({
    super.key,
    required this.ad,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
  });

  final SponsoredAd ad;
  final EdgeInsetsGeometry margin;

  @override
  ConsumerState<SponsoredCard> createState() => _SponsoredCardState();
}

class _SponsoredCardState extends ConsumerState<SponsoredCard>
    with WidgetsBindingObserver {
  bool _didTrackImpression = false;
  bool _isAppInForeground = true;

  /// Minimum time the card must stay ≥50% visible before the impression
  /// counts — matches industry viewability standards and stops drive-by
  /// slot renders from inflating campaign counts (and burning caps).
  static const Duration _minDwellTime = Duration(seconds: 1);
  Timer? _dwellTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _isAppInForeground = state == AppLifecycleState.resumed;
  }

  @override
  void didUpdateWidget(covariant SponsoredCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ad.creativeId != widget.ad.creativeId) {
      _resetImpressionTracking();
    }
  }

  void _resetImpressionTracking() {
    _didTrackImpression = false;
    _dwellTimer?.cancel();
    _dwellTimer = null;
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    final isVisible = _isAppInForeground && info.visibleFraction >= 0.5;
    if (!_didTrackImpression && isVisible) {
      // Start (or keep) the dwell timer; the impression only counts if the
      // card remains visible for the full dwell time.
      _dwellTimer ??= Timer(_minDwellTime, () {
        _dwellTimer = null;
        if (!_didTrackImpression && _isAppInForeground && mounted) {
          _didTrackImpression = true;
          unawaited(_recordImpression());
        }
      });
    } else if (!isVisible && _dwellTimer != null) {
      // Card left the viewport (or app backgrounded) before the dwell
      // elapsed — no impression.
      _dwellTimer?.cancel();
      _dwellTimer = null;
    }
  }

  Future<void> _recordImpression() async {
    try {
      await ref.read(adServiceProvider).recordImpression(widget.ad);
    } catch (e) {
      if (kDebugMode) {
        print('[SponsoredCard] impression recording failed: $e');
      }
    }
  }

  /// Ad image loader with debug visibility: image load failures render as an
  /// invisible blank (by design, no broken-image chrome), so without this log
  /// a broken URL or blocked download is indistinguishable from "no image".
  Widget _adImage() {
    final url = widget.ad.imageUrl!.trim();
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.contain,
      width: double.infinity,
      placeholder: (context, url) => const SizedBox.shrink(),
      errorWidget: (context, url, error) {
        if (kDebugMode) {
          print('[SponsoredCard] ad image FAILED to load: $url -> $error');
        }
        return const SizedBox.shrink();
      },
    );
  }

  bool _isOpeningLink = false;

  Future<void> _openSponsorLink() async {
    // Prevent double-clicks
    if (_isOpeningLink) return;
    _isOpeningLink = true;

    try {
      final l10n = ref.read(localizationProvider);
      final uri = Uri.tryParse(widget.ad.destinationUrl);
      if (uri == null || !uri.hasScheme) {
        _showSnackBar(l10n.getString('adsOpenLinkFailed'));
        return;
      }

      // Open link immediately (don't wait for click recording)
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);

      // Record click in background (don't block UI)
      unawaited(ref.read(adServiceProvider).recordClick(widget.ad));

      if (!opened) {
        _showSnackBar(l10n.getString('adsOpenLinkFailed'));
      }
    } finally {
      // Reset after a short delay to prevent rapid-fire clicks
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          setState(() => _isOpeningLink = false);
        }
      });
    }
  }

  Future<void> _handleImageTap() async {
    if (!widget.ad.hasImage) return;

    final hasValidUrl =
        widget.ad.destinationUrl.trim().isNotEmpty &&
        (widget.ad.destinationUrl.startsWith('http://') ||
            widget.ad.destinationUrl.startsWith('https://'));

    if (hasValidUrl) {
      await _openSponsorLink();
    } else {
      // Show enlarged image
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => _ImageViewerDialog(imageUrl: widget.ad.imageUrl!),
      );
    }
  }

  Future<void> _reportAd() async {
    final l10n = ref.read(localizationProvider);
    final success = await ref.read(adServiceProvider).reportAd(widget.ad);
    _showSnackBar(
      success
          ? l10n.getString('adsReportSubmitted')
          : l10n.getString('adsReportFailed'),
    );
  }

  Future<void> _showWhyDialog() async {
    final l10n = ref.read(localizationProvider);
    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.getString('adsWhyAmISeeingThisTitle')),
          content: Text(l10n.getString('adsWhyAmISeeingThisBody')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.getString('generalClose')),
            ),
          ],
        );
      },
    );
  }

  void _showSnackBar(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);

    final hasValidUrl =
        widget.ad.destinationUrl.trim().isNotEmpty &&
        (widget.ad.destinationUrl.startsWith('http://') ||
            widget.ad.destinationUrl.startsWith('https://'));

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header row with Sponsored badge and action buttons
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  l10n.getString('adsSponsoredLabel'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: _showWhyDialog,
                icon: const Icon(Icons.info_outline, size: 18),
                tooltip: l10n.getString('adsWhyAmISeeingThisTitle'),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                visualDensity: VisualDensity.compact,
              ),
              Builder(
                builder: (context) {
                  final config = ref.watch(appConfigProvider);
                  final reportEnabled =
                      (config['ads.internal.report_enabled']?.toLowerCase() ??
                          'true') ==
                      'true';
                  if (!reportEnabled) return const SizedBox.shrink();
                  return IconButton(
                    onPressed: _reportAd,
                    icon: const Icon(Icons.flag_outlined, size: 18),
                    tooltip: l10n.getString('adsReportAction'),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    visualDensity: VisualDensity.compact,
                  );
                },
              ),
            ],
          ),
          // Content
          if (widget.ad.sponsorName.trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              l10n.getString(
                'adsSponsoredBy',
                params: {'sponsor': widget.ad.sponsorName.trim()},
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ] else
            const SizedBox(height: 4),
          Text(
            widget.ad.headline,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (widget.ad.hasBody) ...[
            const SizedBox(height: 2),
            Text(widget.ad.body!.trim(), style: theme.textTheme.bodySmall),
          ],
          // Image (only clickable if no destination URL)
          if (widget.ad.hasImage) ...[
            const SizedBox(height: 6),
            if (!hasValidUrl)
              GestureDetector(
                onTap: _handleImageTap,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 200),
                      width: double.infinity,
                      child: _adImage(),
                    ),
                  ),
                ),
              )
            else
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  width: double.infinity,
                  child: _adImage(),
                ),
              ),
          ],
        ],
      ),
    );

    return VisibilityDetector(
      key: Key('visibility_${widget.ad.creativeId}'),
      onVisibilityChanged: _onVisibilityChanged,
      child: Container(
        margin: widget.margin,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.5),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.shadow.withValues(alpha: 0.08),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: hasValidUrl
            ? MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior:
                      HitTestBehavior.opaque, // Ensure entire area is tappable
                  onTap: _isOpeningLink
                      ? null
                      : _openSponsorLink, // Disable while opening
                  child: Material(
                    // Add Material for ripple effect
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      onTap: _isOpeningLink ? null : _openSponsorLink,
                      borderRadius: BorderRadius.circular(12),
                      child: content,
                    ),
                  ),
                ),
              )
            : content,
      ),
    );
  }

  @override
  void dispose() {
    _dwellTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
