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
import 'package:flutter/foundation.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:extended_image/extended_image.dart';
import 'dart:developer' as developer;

class SignedImage extends StatefulWidget {
  final String
  source; // either "https://..." or "userId/123.jpg" or a public supabase URL
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
    developer.log(
      '🖼️ SignedImage init: source=${widget.source}, cacheKey=$_lastCacheKey, bucket=${widget.bucket}',
      name: 'MatchMeTrace',
    );
    _initResolve();
  }

  @override
  void didUpdateWidget(covariant SignedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newCacheKey = StorageHelper.cacheKeyForSource(widget.source);
    if (oldWidget.source != widget.source || _lastCacheKey != newCacheKey) {
      developer.log(
        '🖼️ SignedImage update: sourceChanged=${oldWidget.source != widget.source}, cacheKeyChanged=${_lastCacheKey != newCacheKey}, source=${widget.source}, cacheKey=$newCacheKey',
        name: 'MatchMeTrace',
      );
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

  String? _cacheFallbackUrl() {
    if (widget.source.isEmpty) return null;
    // Don't try fallback URL for known-missing objects
    if (StorageHelper.isKnownMissing(widget.source, bucket: widget.bucket)) {
      return null;
    }
    if (widget.source.startsWith('http://') ||
        widget.source.startsWith('https://')) {
      return widget.source;
    }
    return StorageHelper.buildPublicObjectUrl(
      widget.source,
      bucket: widget.bucket,
    );
  }

  Widget _buildCachedNetworkImage(
    String imageUrl,
    String cacheKey, {
    Map<String, String>? headers,
  }) {
    if (kIsWeb) {
      return Image.network(
        imageUrl,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        alignment: widget.alignment,
        headers: null,
        filterQuality: widget.filterQualityLow
            ? FilterQuality.low
            : FilterQuality.high,
        webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return SizedBox(
            width: widget.width,
            height: widget.height,
            child:
                widget.placeholder ??
                const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
          );
        },
        errorBuilder: (context, error, stackTrace) {
          return widget.errorWidget ?? const Icon(Icons.broken_image);
        },
      );
    }

    return ExtendedImage.network(
      imageUrl,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      alignment: widget.alignment,
      headers: headers,
      cache: true,
      cacheKey: cacheKey.isNotEmpty ? cacheKey : null,
      filterQuality: widget.filterQualityLow
          ? FilterQuality.low
          : FilterQuality.high,
      loadStateChanged: (state) {
        switch (state.extendedImageLoadState) {
          case LoadState.loading:
            return SizedBox(
              width: widget.width,
              height: widget.height,
              child:
                  widget.placeholder ??
                  const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
            );
          case LoadState.completed:
            return ExtendedRawImage(
              image: state.extendedImageInfo?.image,
              fit: widget.fit,
              width: widget.width,
              height: widget.height,
              alignment: widget.alignment,
              filterQuality: widget.filterQualityLow
                  ? FilterQuality.low
                  : FilterQuality.high,
            );
          case LoadState.failed:
            return widget.errorWidget ?? const Icon(Icons.broken_image);
        }
      },
    );
  }

  Future<void> _initResolve() async {
    final generation = ++_resolveGeneration;
    final src = widget.source;
    developer.log(
      '🖼️ SignedImage resolve start: source=$src, gen=$generation, bucket=${widget.bucket}',
      name: 'MatchMeTrace',
    );
    if (src.isEmpty) {
      setState(() {
        _failed = true;
      });
      return;
    }

    if (offlineCacheManager.shouldUseCachedData()) {
      final headers = StorageHelper.buildAuthHeaders();
      final directUrl = headers != null
          ? StorageHelper.buildAuthenticatedObjectUrl(
              src,
              bucket: widget.bucket,
            )
          : null;
      final fallbackUrl = directUrl ?? _cacheFallbackUrl();
      if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
        setState(() {
          _resolvedUrl = fallbackUrl;
          _resolvedHeaders =
              directUrl == fallbackUrl && headers != null && headers.isNotEmpty
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

    // Otherwise, ask StorageHelper to create one (once).
    setState(() {
      _failed = false;
    });

    try {
      final request = await StorageHelper.resolveImageRequest(
        src,
        bucket: widget.bucket,
      );
      if (!mounted) return;
      if (generation != _resolveGeneration) return;
      if (request == null || request.url.isEmpty) {
        developer.log(
          '🖼️ SignedImage resolve: signed url missing',
          name: 'MatchMeTrace',
        );
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
      developer.log(
        '🖼️ SignedImage resolve: signed url resolved',
        name: 'MatchMeTrace',
      );
      setState(() {
        _resolvedUrl = request.url;
        _resolvedHeaders = request.headers;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (generation != _resolveGeneration) return;
      developer.log(
        '🖼️ SignedImage resolve: error creating signed url',
        name: 'MatchMeTrace',
      );
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
      return _buildCachedNetworkImage(
        _resolvedUrl!,
        cacheKey,
        headers: _resolvedHeaders,
      );
    }

    if (_failed) {
      final fallbackUrl = _cacheFallbackUrl();
      if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
        return _buildCachedNetworkImage(fallbackUrl, cacheKey);
      }

      if (StorageHelper.isKnownMissing(widget.source, bucket: widget.bucket)) {
        return SizedBox(width: widget.width, height: widget.height);
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
      child:
          widget.placeholder ??
          const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
    );
  }
}
