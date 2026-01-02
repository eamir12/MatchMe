// lib/widgets/signed_image.dart
// Stateful SignedImage that caches the resolved signed URL per widget instance
// and avoids recreating the signing Future each build (prevents continuous createSignedUrl calls).
//
// Note: we detect already-signed URLs locally (don't rely on private helpers in StorageHelper).
//
// Behavior:
// - If source is already a signed URL (contains token or X-Amz-), use it directly.
// - If StorageHelper.getCachedUrl(source) returns a cached signed URL, use that immediately.
// - Otherwise request a signed URL once in initState / when source changes and store the result.
// - While waiting, show placeholder; on failure show errorWidget (or a fallback broken image).

import 'package:flutter/material.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:extended_image/extended_image.dart';

class SignedImage extends StatefulWidget {
  final String source; // either "https://..." or "userId/123.jpg" or a public supabase URL
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? placeholder;
  final Widget? errorWidget;
  final Alignment alignment;
  final bool filterQualityLow;

  const SignedImage({
    super.key,
    required this.source,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
    this.errorWidget,
    this.alignment = Alignment.center,
    this.filterQualityLow = false,
  });

  @override
  State<SignedImage> createState() => _SignedImageState();
}

class _SignedImageState extends State<SignedImage> {
  String? _resolvedUrl;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _initResolve();
  }

  @override
  void didUpdateWidget(covariant SignedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _resolvedUrl = null;
      _failed = false;
      _initResolve();
    }
  }

  // Local check for already-signed URLs (don't call private members of StorageHelper).
  bool _looksLikeSignedUrl(String urlOrPath) {
    try {
      final uri = Uri.parse(urlOrPath);
      if (uri.queryParameters.containsKey('token')) return true;
      if (uri.query.isNotEmpty && (uri.query.contains('X-Amz-') || uri.query.contains('X-Amz-Signature'))) return true;
    } catch (_) {}
    return false;
  }

  Future<void> _initResolve() async {
    final src = widget.source;
    if (src.isEmpty) {
      setState(() {
        _failed = true;
      });
      return;
    }

    // If it already looks like a signed url, use it immediately.
    if (_looksLikeSignedUrl(src)) {
      setState(() {
        _resolvedUrl = src;
        _failed = false;
      });
      return;
    }

    // If a cached signed URL exists, use it.
    final cached = StorageHelper.getCachedUrl(src);
    if (cached != null && cached.isNotEmpty) {
      setState(() {
        _resolvedUrl = cached;
        _failed = false;
      });
      return;
    }

    // Otherwise, ask StorageHelper to create one (once).
    setState(() {
      _failed = false;
    });

    try {
      final signed = await StorageHelper.getSignedUrl(src);
      if (!mounted) return;
      if (signed == null || signed.isEmpty) {
        setState(() {
          _failed = true;
        });
        return;
      }
      setState(() {
        _resolvedUrl = signed;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cacheKey = StorageHelper.cacheKeyForSource(widget.source);
    // Priority: resolved url -> errorWidget -> placeholder (if loading) -> small broken icon
    if (_resolvedUrl != null && _resolvedUrl!.isNotEmpty) {
      return ExtendedImage.network(
        _resolvedUrl!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        alignment: widget.alignment,
        cache: true,
        cacheKey: cacheKey.isNotEmpty ? cacheKey : null,
        filterQuality: widget.filterQualityLow ? FilterQuality.low : FilterQuality.high,
        loadStateChanged: (state) {
          switch (state.extendedImageLoadState) {
            case LoadState.loading:
              return SizedBox(
                width: widget.width,
                height: widget.height,
                child: widget.placeholder ??
                    const Center(
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
              );
            case LoadState.completed:
              return ExtendedRawImage(image: state.extendedImageInfo?.image, fit: widget.fit, width: widget.width, height: widget.height, alignment: widget.alignment, filterQuality: widget.filterQualityLow ? FilterQuality.low : FilterQuality.high);
            case LoadState.failed:
              return widget.errorWidget ?? const Icon(Icons.broken_image);
          }
        },
      );
    }

    if (_failed) {
      // Try using public URL as fallback
      final publicUrl = StorageHelper.constructPublicUrl(widget.source);
      if (publicUrl != null) {
        return ExtendedImage.network(
          publicUrl,
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
          alignment: widget.alignment,
          cache: true,
          cacheKey: cacheKey.isNotEmpty ? cacheKey : null,
          filterQuality: widget.filterQualityLow ? FilterQuality.low : FilterQuality.high,
          loadStateChanged: (state) {
            switch (state.extendedImageLoadState) {
              case LoadState.loading:
                return SizedBox(
                  width: widget.width,
                  height: widget.height,
                  child: widget.placeholder ??
                      const Center(
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                );
              case LoadState.completed:
                return ExtendedRawImage(image: state.extendedImageInfo?.image, fit: widget.fit, width: widget.width, height: widget.height, alignment: widget.alignment, filterQuality: widget.filterQualityLow ? FilterQuality.low : FilterQuality.high);
              case LoadState.failed:
                return widget.errorWidget ?? const Icon(Icons.broken_image);
            }
          },
        );
      }

      // Try using original source as last-resort if it is an http URL (some objects may be public)
      if (widget.source.startsWith('http://') || widget.source.startsWith('https://')) {
        return ExtendedImage.network(
          widget.source,
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
          alignment: widget.alignment,
          cache: true,
          cacheKey: cacheKey.isNotEmpty ? cacheKey : null,
          filterQuality: widget.filterQualityLow ? FilterQuality.low : FilterQuality.high,
          loadStateChanged: (state) {
            switch (state.extendedImageLoadState) {
              case LoadState.loading:
                return SizedBox(
                  width: widget.width,
                  height: widget.height,
                  child: widget.placeholder ??
                      const Center(
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                );
              case LoadState.completed:
                return ExtendedRawImage(image: state.extendedImageInfo?.image, fit: widget.fit, width: widget.width, height: widget.height, alignment: widget.alignment, filterQuality: widget.filterQualityLow ? FilterQuality.low : FilterQuality.high);
              case LoadState.failed:
                return widget.errorWidget ?? const Icon(Icons.broken_image);
            }
          },
        );
      }

      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: widget.errorWidget ?? const Icon(Icons.broken_image),
      );
    }

    // Loading state
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: widget.placeholder ??
          const Center(
            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
    );
  }
}
