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
import 'dart:developer' as developer;

class SignedImage extends StatefulWidget {
  final String source; // either "https://..." or "userId/123.jpg" or a public supabase URL
  final String? bucket; // optional bucket name, defaults to 'profile-photos'
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
    this.bucket,
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
  Map<String, String>? _resolvedHeaders;
  bool _failed = false;
  int _resolveGeneration = 0;
  int _retryCount = 0;
  String? _lastCacheKey;

  @override
  void initState() {
    super.initState();
    _lastCacheKey = StorageHelper.cacheKeyForSource(widget.source);
    developer.log('🖼️ SignedImage init: source=${widget.source}, cacheKey=$_lastCacheKey, bucket=${widget.bucket}', name: 'MatchMeTrace');
    _initResolve();
  }

  @override
  void didUpdateWidget(covariant SignedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newCacheKey = StorageHelper.cacheKeyForSource(widget.source);
    if (oldWidget.source != widget.source || _lastCacheKey != newCacheKey) {
      developer.log('🖼️ SignedImage update: sourceChanged=${oldWidget.source != widget.source}, cacheKeyChanged=${_lastCacheKey != newCacheKey}, source=${widget.source}, cacheKey=$newCacheKey', name: 'MatchMeTrace');
      _resolvedUrl = null;
      _resolvedHeaders = null;
      _failed = false;
      _retryCount = 0;
      _lastCacheKey = newCacheKey;
      _initResolve();
      return;
    }
    _lastCacheKey = newCacheKey;
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
    final generation = ++_resolveGeneration;
    final src = widget.source;
    developer.log('🖼️ SignedImage resolve start: source=$src, gen=$generation, bucket=${widget.bucket}', name: 'MatchMeTrace');
    if (src.isEmpty) {
      setState(() {
        _failed = true;
      });
      return;
    }

    // If it already looks like a signed url, use it immediately.
    if (_looksLikeSignedUrl(src)) {
      developer.log('🖼️ SignedImage resolve: using existing signed url', name: 'MatchMeTrace');
      setState(() {
        _resolvedUrl = src;
        _resolvedHeaders = null;
        _failed = false;
      });
      return;
    }

    // If a cached signed URL exists, use it.
    final cached = StorageHelper.getCachedUrl(src, bucket: widget.bucket);
    if (cached != null && cached.isNotEmpty) {
      developer.log('🖼️ SignedImage resolve: using cached signed url', name: 'MatchMeTrace');
      setState(() {
        _resolvedUrl = cached;
        _resolvedHeaders = null;
        _failed = false;
      });
      return;
    }

    // Otherwise, ask StorageHelper to create one (once).
    setState(() {
      _failed = false;
    });

    try {
      final signed = widget.bucket != null
          ? await StorageHelper.getSignedUrlFromBucket(src, widget.bucket!)
          : await StorageHelper.getSignedUrl(src);
      if (!mounted) return;
      if (generation != _resolveGeneration) return;
      if (signed == null || signed.isEmpty) {
        developer.log('🖼️ SignedImage resolve: signed url missing', name: 'MatchMeTrace');
        final headers = StorageHelper.buildAuthHeaders();
        final direct = headers != null
            ? StorageHelper.buildAuthenticatedObjectUrl(src, bucket: widget.bucket)
            : null;
        if (direct != null && direct.isNotEmpty && headers != null && headers.isNotEmpty) {
          setState(() {
            _resolvedUrl = direct;
            _resolvedHeaders = headers;
            _failed = false;
          });
          return;
        }
        if (!StorageHelper.canCreateSignedUrls && _retryCount < 12) {
          _retryCount++;
          Future.delayed(const Duration(milliseconds: 400), () {
            if (!mounted) return;
            if (generation != _resolveGeneration) return;
            _initResolve();
          });
          return;
        }
        setState(() {
          _failed = true;
        });
        return;
      }
      _retryCount = 0;
      developer.log('🖼️ SignedImage resolve: signed url resolved', name: 'MatchMeTrace');
      setState(() {
        _resolvedUrl = signed;
        _resolvedHeaders = null;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (generation != _resolveGeneration) return;
      developer.log('🖼️ SignedImage resolve: error creating signed url', name: 'MatchMeTrace');
      if (!StorageHelper.canCreateSignedUrls && _retryCount < 12) {
        _retryCount++;
        Future.delayed(const Duration(milliseconds: 400), () {
          if (!mounted) return;
          if (generation != _resolveGeneration) return;
          _initResolve();
        });
        return;
      }
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
      final headers = _resolvedHeaders;
      if (headers != null && headers.isNotEmpty) {
        return Image.network(
          _resolvedUrl!,
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
          alignment: widget.alignment,
          headers: headers,
          filterQuality: widget.filterQualityLow ? FilterQuality.low : FilterQuality.high,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return SizedBox(
              width: widget.width,
              height: widget.height,
              child: widget.placeholder ??
                  const Center(
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
            );
          },
          errorBuilder: (context, error, stackTrace) {
            return widget.errorWidget ?? const Icon(Icons.broken_image);
          },
        );
      }
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
