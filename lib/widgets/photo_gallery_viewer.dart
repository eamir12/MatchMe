// lib/widgets/photo_gallery_viewer.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:extended_image/extended_image.dart';
import 'package:http/http.dart' as http;
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/services/offline_cache_manager.dart';
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
  String? _resolvedUrl;
  Map<String, String>? _resolvedHeaders;
  Uint8List? _cachedWebImageBytes;
  bool _failed = false;
  int _resolveGeneration = 0;

  @override
  void initState() {
    super.initState();
    _resolveUrl();
  }

  @override
  void didUpdateWidget(covariant _GalleryImageItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _resolvedUrl = null;
      _resolvedHeaders = null;
      _cachedWebImageBytes = null;
      _failed = false;
      _resolveUrl();
    }
  }

  String? _fallbackUrl() {
    if (widget.source.isEmpty) return null;
    if (StorageHelper.isKnownMissing(widget.source, bucket: 'profile-photos')) {
      return null;
    }
    if (widget.source.startsWith('http://') ||
        widget.source.startsWith('https://')) {
      return widget.source;
    }
    return StorageHelper.buildPublicObjectUrl(
      widget.source,
      bucket: 'profile-photos',
    );
  }

  Future<void> _resolveUrl() async {
    final generation = ++_resolveGeneration;
    final src = widget.source;
    if (src.isEmpty) {
      setState(() {
        _failed = true;
      });
      return;
    }

    final cacheKey = StorageHelper.cacheKeyForSource(src);
    if (kIsWeb) {
      try {
        final cachedBytes = await OfflineImageCache.instance.read(cacheKey);
        if (!mounted || generation != _resolveGeneration) return;
        if (cachedBytes != null) {
          setState(() => _cachedWebImageBytes = cachedBytes);
        }
      } catch (error) {
        debugPrint('Photo gallery offline cache read failed: $error');
      }
      if (offlineCacheManager.shouldUseCachedData()) {
        if (_cachedWebImageBytes == null && mounted) {
          setState(() => _failed = true);
        }
        return;
      }
    }

    if (offlineCacheManager.shouldUseCachedData()) {
      final headers = StorageHelper.buildAuthHeaders();
      final directUrl = headers != null
          ? StorageHelper.buildAuthenticatedObjectUrl(
              src,
              bucket: 'profile-photos',
            )
          : null;
      final fallback = directUrl ?? _fallbackUrl();
      if (fallback != null && fallback.isNotEmpty) {
        setState(() {
          _resolvedUrl = fallback;
          _resolvedHeaders = (directUrl == fallback && headers != null)
              ? headers
              : null;
          _failed = false;
        });
        return;
      }
      setState(() {
        _failed = true;
      });
      return;
    }

    try {
      final request = await StorageHelper.resolveImageRequest(
        src,
        bucket: 'profile-photos',
      );
      if (!mounted || generation != _resolveGeneration) return;
      if (request == null || request.url.isEmpty) {
        setState(() {
          _failed = true;
        });
        return;
      }
      setState(() {
        _resolvedUrl = request.url;
        _resolvedHeaders = request.headers;
        _failed = false;
      });
      if (kIsWeb) {
        unawaited(_cacheWebImageBytes(request.url, request.headers, cacheKey));
      }
    } catch (_) {
      if (!mounted || generation != _resolveGeneration) return;
      setState(() {
        _failed = true;
      });
    }
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
    if (kIsWeb && _cachedWebImageBytes != null) {
      return ExtendedImage.memory(
        _cachedWebImageBytes!,
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
    if (_resolvedUrl == null && !_failed) {
      return const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final displayUrl = _resolvedUrl ?? _fallbackUrl();
    if (displayUrl == null || displayUrl.isEmpty) {
      return Center(
        child: Text(
          _getErrorMessage(),
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }

    if (kIsWeb) {
      return Center(
        child: Image.network(
          displayUrl,
          headers: null,
          fit: BoxFit.contain,
          webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return const Center(
              child: SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          },
          errorBuilder: (context, error, stackTrace) {
            return Center(
              child: Text(
                _getErrorMessage(),
                style: const TextStyle(color: Colors.white70),
              ),
            );
          },
        ),
      );
    }

    return ExtendedImage.network(
      displayUrl,
      headers: _resolvedHeaders,
      cache: true,
      cacheKey: StorageHelper.cacheKeyForSource(widget.source),
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
        switch (state.extendedImageLoadState) {
          case LoadState.loading:
            return const Center(
              child: SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          case LoadState.completed:
            // Returning null allows default image rendering (gesture works)
            return null;
          case LoadState.failed:
            return Center(
              child: Text(
                _getErrorMessage(),
                style: const TextStyle(color: Colors.white70),
              ),
            );
        }
      },
    );
  }

  Future<void> _cacheWebImageBytes(
    String url,
    Map<String, String>? headers,
    String cacheKey,
  ) async {
    try {
      final response = await http.get(Uri.parse(url), headers: headers);
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw StateError('Image fetch failed with HTTP ${response.statusCode}');
      }
      final bytes = Uint8List.fromList(response.bodyBytes);
      await OfflineImageCache.instance.write(cacheKey, bytes);
      if (!mounted ||
          cacheKey != StorageHelper.cacheKeyForSource(widget.source)) {
        return;
      }
      setState(() => _cachedWebImageBytes = bytes);
    } catch (error) {
      debugPrint('Photo gallery image could not be cached: $error');
    }
  }
}
