// lib/widgets/signed_image.dart
// Bytes-first SignedImage: paints from the encrypted OfflineImageCache
// (raw bytes, cleared on logout) whenever possible, so avatars and photos
// appear within one frame of mount on warm relaunches — no signed-URL
// resolution, no network, no extended_image decode pipeline.
//
// On cache miss: resolve a signed URL once, download through
// StorageHelper.fetchImageBytesFromUrl (shared, in-flight deduped,
// persists bytes into OfflineImageCache), then paint from memory.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/offline_image_cache.dart';
import 'package:matchme/services/storage_helper.dart';

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

  /// Reports the decoded bytes whenever they become available (or `null`
  /// when loading fails), so callers can measure the image and lay out an
  /// overlay (e.g. normalized boxes) against the real aspect ratio.
  final ValueChanged<Uint8List?>? onBytesLoaded;

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
    this.onBytesLoaded,
  });

  @override
  State<SignedImage> createState() => _SignedImageState();
}

class _SignedImageState extends State<SignedImage> {
  Uint8List? _bytes;
  bool _failed = false;
  int _loadGeneration = 0;
  int _retryCount = 0;
  String? _lastCacheKey;
  Uint8List? _lastNotifiedBytes;
  ValueChanged<Uint8List?>? _lastNotifiedCallback;
  bool _hasNotifiedBytes = false;

  void _notifyBytesLoaded() {
    final callback = widget.onBytesLoaded;
    if (callback == null) return;
    final bytes = _bytes;
    if (_hasNotifiedBytes &&
        identical(bytes, _lastNotifiedBytes) &&
        callback == _lastNotifiedCallback) {
      return;
    }
    _hasNotifiedBytes = true;
    _lastNotifiedBytes = bytes;
    _lastNotifiedCallback = callback;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      callback(_bytes);
    });
  }

  @override
  void initState() {
    super.initState();
    _lastCacheKey = StorageHelper.cacheKeyForSource(widget.source);
    final hot = OfflineImageCache.instance.peek(_lastCacheKey ?? '');
    if (hot != null) {
      // Sync hot-cache hit: paints in this very frame.
      _bytes = hot;
    } else {
      unawaited(_load());
    }
  }

  @override
  void didUpdateWidget(covariant SignedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newCacheKey = StorageHelper.cacheKeyForSource(widget.source);
    if (oldWidget.source != widget.source || _lastCacheKey != newCacheKey) {
      _loadGeneration++;
      _failed = false;
      _retryCount = 0;
      _lastCacheKey = newCacheKey;
      final hot = OfflineImageCache.instance.peek(newCacheKey);
      if (hot != null) {
        _bytes = hot;
      } else {
        _bytes = null;
        unawaited(_load());
      }
      return;
    }
    _lastCacheKey = newCacheKey;
  }

  /// Physical-pixel width to decode at, derived from the widget's logical
  /// width and the current device pixel ratio (capped at 2048).
  ///
  /// Decoding a 1080x1080 photo for a 56px avatar costs ~100-300ms of decode
  /// per row on low-end devices and bloats the ImageCache ~40x — the main
  /// reason avatars pop in late on Home. Downsampled decode is ~5ms.
  int? _decodeCacheWidth() {
    final w = widget.width;
    if (w == null || w <= 0 || !w.isFinite) return null;
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final px = (w * dpr).ceil();
    if (px <= 0) return null;
    return px > 2048 ? 2048 : px;
  }

  String? _fallbackUrl() {
    if (widget.source.isEmpty) return null;
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

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final src = widget.source;
    if (src.isEmpty) {
      if (mounted) {
        setState(() => _failed = true);
      }
      return;
    }

    final cacheKey = StorageHelper.cacheKeyForSource(src);

    // 1. Persistent encrypted byte cache (survives relaunch): paints with
    // zero network and zero signed-URL work.
    final cached = await OfflineImageCache.instance.read(cacheKey);
    if (!mounted || generation != _loadGeneration) return;
    if (cached != null) {
      setState(() {
        _bytes = cached;
        _failed = false;
      });
      return;
    }

    // 2. Offline (Supabase unreachable): best-effort fetch from the
    // direct/authenticated or public URL; otherwise fail fast.
    if (offlineCacheManager.shouldUseCachedData()) {
      final bytes = await _fetchDirectOrFallback(cacheKey);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _bytes = bytes;
        _failed = bytes == null;
      });
      return;
    }

    // 3. Online: resolve a signed URL once, download bytes (shared
    // in-flight dedup; persists into OfflineImageCache), then paint.
    ResolvedImageRequest? request;
    try {
      request = await StorageHelper.resolveImageRequest(
        src,
        bucket: widget.bucket,
      );
    } catch (_) {
      request = null;
    }
    if (!mounted || generation != _loadGeneration) return;

    if (request == null || request.url.isEmpty) {
      if (!_canCreateSignedUrlsSafe() && _retryCount < 12) {
        _retryCount++;
        Future.delayed(const Duration(milliseconds: 400), () {
          if (!mounted || generation != _loadGeneration) return;
          unawaited(_load());
        });
        return;
      }
      final bytes = await _fetchDirectOrFallback(cacheKey);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _bytes = bytes;
        _failed = bytes == null;
      });
      return;
    }

    _retryCount = 0;
    var bytes = await StorageHelper.fetchImageBytesFromUrl(
      request.url,
      headers: request.headers,
      cacheKey: cacheKey,
      objectPath: src,
    );
    if (!mounted || generation != _loadGeneration) return;
    if (bytes == null) {
      // Signed URL fetch failed (expired, revoked, network blip): try the
      // public/fallback URL once before giving up.
      bytes = await _fetchDirectOrFallback(cacheKey);
      if (!mounted || generation != _loadGeneration) return;
    }
    setState(() {
      _bytes = bytes;
      _failed = bytes == null;
    });
  }

  /// Best-effort fetch used when signed-URL creation is unavailable (offline
  /// or session not ready): prefer the authenticated direct-object URL,
  /// else the public/source URL.
  Future<Uint8List?> _fetchDirectOrFallback(String cacheKey) async {
    Map<String, String>? headers;
    String? url;
    try {
      headers = StorageHelper.buildAuthHeaders();
      if (headers != null) {
        url = StorageHelper.buildAuthenticatedObjectUrl(
          widget.source,
          bucket: widget.bucket,
        );
      }
    } catch (_) {
      headers = null;
    }
    if (url == null || url.isEmpty) {
      url = _fallbackUrl();
      headers = null;
    }
    if (url == null || url.isEmpty) return null;
    // objectPath is only honored for authorized requests (see
    // StorageHelper._isAuthorizedImageRequest), so passing it for the
    // public-URL fallback is safe.
    return StorageHelper.fetchImageBytesFromUrl(
      url,
      headers: headers,
      cacheKey: cacheKey,
      objectPath: widget.source,
    );
  }

  /// `canCreateSignedUrls` reads `Supabase.instance`, which can throw when
  /// Supabase is not initialized (e.g. widget tests).
  bool _canCreateSignedUrlsSafe() {
    try {
      return StorageHelper.canCreateSignedUrls;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleDecodeFailure() async {
    final key = _lastCacheKey;
    if (key != null && key.isNotEmpty) {
      await OfflineImageCache.instance.evict(key);
    }
    if (!mounted) return;
    // errorBuilder runs during build; defer the state change one frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _bytes = null;
        _failed = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    _notifyBytesLoaded();
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        alignment: widget.alignment,
        cacheWidth: _decodeCacheWidth(),
        gaplessPlayback: true,
        filterQuality: widget.filterQualityLow
            ? FilterQuality.low
            : FilterQuality.high,
        errorBuilder: (context, error, stackTrace) {
          unawaited(_handleDecodeFailure());
          return widget.errorWidget ?? const Icon(Icons.broken_image);
        },
      );
    }

    if (_failed) {
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
