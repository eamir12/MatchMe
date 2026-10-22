// lib/widgets/photo_gallery_viewer.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:extended_image/extended_image.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/services/offline_image_cache.dart';
import 'package:matchme/providers/locale_provider.dart';

class PhotoGalleryViewer extends StatefulWidget {
  final List<String> photos;
  final int initialIndex;
  final LocalizationState l10n;

  const PhotoGalleryViewer({
    super.key,
    required this.photos,
    required this.initialIndex,
    required this.l10n,
  });

  @override
  State<PhotoGalleryViewer> createState() => _PhotoGalleryViewerState();
}

class _PhotoGalleryViewerState extends State<PhotoGalleryViewer> {
  late int _currentIndex;
  late final ExtendedPageController _pageController;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = ExtendedPageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goToPrevious() {
    if (_currentIndex > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToNext() {
    if (_currentIndex < widget.photos.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final showNavigation = widget.photos.length > 1;
    final isRtl = widget.l10n.textDirection == TextDirection.rtl;

    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.black,
      child: SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Main Swiper (ExtendedImageGesturePageView)
            ExtendedImageGesturePageView.builder(
              controller: _pageController,
              itemCount: widget.photos.length,
              scrollDirection: Axis.horizontal,
              onPageChanged: (index) {
                setState(() {
                  _currentIndex = index;
                });
              },
              itemBuilder: (context, index) {
                return _GalleryImageItem(
                  source: widget.photos[index],
                  l10n: widget.l10n,
                );
              },
            ),

            // Top Header: Close Button and Page Indicator
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              left: 16,
              right: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Back / Close Button (Respect RTL/LTR for position)
                  if (!isRtl)
                    IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 28,
                      ),
                      onPressed: () => Navigator.of(context).maybePop(),
                    )
                  else
                    const SizedBox(width: 48), // Spacer to balance layout
                  // Centered Page Indicator
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      '${_currentIndex + 1} / ${widget.photos.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),

                  // Opposite position close button for RTL
                  if (isRtl)
                    IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 28,
                      ),
                      onPressed: () => Navigator.of(context).maybePop(),
                    )
                  else
                    const SizedBox(width: 48), // Spacer to balance layout
                ],
              ),
            ),

            // Navigation Chevron Buttons (Web/Desktop or general convenience)
            // Spatial controls: the left-edge button always points left and
            // the right-edge button always points right, regardless of UI
            // language. `textDirection: TextDirection.ltr` opts out of the
            // automatic RTL mirroring (`matchTextDirection: true`) so Hebrew
            // does not flip them.
            if (showNavigation) ...[
              // Left / Previous Button
              Positioned(
                left: 16,
                child: _currentIndex > 0
                    ? Container(
                        decoration: const BoxDecoration(
                          color: Colors.black45,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: const Icon(
                            Icons.chevron_left,
                            color: Colors.white,
                            size: 32,
                            textDirection: TextDirection.ltr,
                          ),
                          onPressed: _goToPrevious,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),

              // Right / Next Button
              Positioned(
                right: 16,
                child: _currentIndex < widget.photos.length - 1
                    ? Container(
                        decoration: const BoxDecoration(
                          color: Colors.black45,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: const Icon(
                            Icons.chevron_right,
                            color: Colors.white,
                            size: 32,
                            textDirection: TextDirection.ltr,
                          ),
                          onPressed: _goToNext,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],

            // Bottom Pagination Indicator Dots
            if (showNavigation)
              Positioned(
                bottom: MediaQuery.of(context).padding.bottom + 24,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(widget.photos.length, (index) {
                    final isActive = index == _currentIndex;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: isActive ? 12 : 8,
                      height: isActive ? 12 : 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isActive ? Colors.white : Colors.white38,
                      ),
                    );
                  }),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GalleryImageItem extends StatefulWidget {
  final String source;
  final LocalizationState l10n;

  const _GalleryImageItem({required this.source, required this.l10n});

  @override
  State<_GalleryImageItem> createState() => _GalleryImageItemState();
}

class _GalleryImageItemState extends State<_GalleryImageItem> {
  Uint8List? _bytes;
  bool _failed = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    final cacheKey = StorageHelper.cacheKeyForSource(widget.source);
    final hot = OfflineImageCache.instance.peek(cacheKey);
    if (hot != null) {
      _bytes = hot;
    } else {
      unawaited(_load());
    }
  }

  @override
  void didUpdateWidget(covariant _GalleryImageItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _loadGeneration++;
      _bytes = null;
      _failed = false;
      final cacheKey = StorageHelper.cacheKeyForSource(widget.source);
      final hot = OfflineImageCache.instance.peek(cacheKey);
      if (hot != null) {
        _bytes = hot;
      } else {
        unawaited(_load());
      }
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final src = widget.source;
    if (src.isEmpty) {
      if (mounted) setState(() => _failed = true);
      return;
    }

    final cacheKey = StorageHelper.cacheKeyForSource(src);
    final cached = await OfflineImageCache.instance.read(cacheKey);
    if (!mounted || generation != _loadGeneration) return;
    if (cached != null && cached.isNotEmpty) {
      setState(() {
        _bytes = cached;
        _failed = false;
      });
      return;
    }

    // Downloads and persists the original bytes. When Supabase is
    // unreachable this returns null instantly for an uncached photo.
    final bytes = await StorageHelper.loadImageBytes(src);
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _bytes = bytes;
      _failed = bytes == null || bytes.isEmpty;
    });
  }

  String _getErrorMessage() {
    try {
      final msg1 = widget.l10n.getString('generalImageLoadFailed');
      if (msg1.trim().isNotEmpty &&
          msg1 != 'generalImageLoadFailed' &&
          !msg1.endsWith('...')) {
        return msg1;
      }
      final msg2 = widget.l10n.getString('failedToLoadImage');
      if (msg2.trim().isNotEmpty &&
          msg2 != 'failedToLoadImage' &&
          !msg2.endsWith('...')) {
        return msg2;
      }
    } catch (_) {}
    return 'Failed to load image';
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null && bytes.isNotEmpty) {
      return ExtendedImage.memory(
        bytes,
        mode: ExtendedImageMode.gesture,
        fit: BoxFit.contain,
        initGestureConfigHandler: (_) => GestureConfig(
          minScale: 1.0,
          maxScale: 5.0,
          animationMinScale: 0.8,
          animationMaxScale: 6.0,
          speed: 1.0,
          inertialSpeed: 100.0,
          initialScale: 1.0,
          inPageView: true,
        ),
        loadStateChanged: (state) {
          if (state.extendedImageLoadState == LoadState.failed) {
            return Center(
              child: Text(
                _getErrorMessage(),
                style: const TextStyle(color: Colors.white70),
              ),
            );
          }
          return null;
        },
      );
    }
    if (_failed) {
      return Center(
        child: Text(
          _getErrorMessage(),
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }
    return const Center(
      child: SizedBox(
        width: 30,
        height: 30,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}
