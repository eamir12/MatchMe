// lib/services/storage_helper.dart
// Helper to create signed URLs for objects in the profile-photos bucket.
// Includes a simple in-memory cache keyed by objectPath with expiry.
// Robustly accepts either an objectPath (userId/123.jpg), an objectPath prefixed
// with the bucket ("profile-photos/userId/123.jpg"), or a Supabase public object URL
// (https://<project>.supabase.co/storage/v1/object/public/profile-photos/...) and
// extracts the objectPath before creating a signed URL.
//
// Notes:
// - createSignedUrl expects the object path relative to the bucket (no "profile-photos/" prefix).
// - If an already-signed URL is passed in (contains token / AWS query params) it will be returned unchanged.
// - If createSignedUrl returns 404 (object not found) we return null so callers can handle gracefully.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/offline_image_cache.dart';
import 'package:matchme/services/runtime_supabase_config.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:http/http.dart' as http;
import 'package:extended_image/extended_image.dart';

class _CacheEntry {
  final String url;
  final DateTime expiresAt;
  _CacheEntry(this.url, this.expiresAt);
}

class ResolvedImageRequest {
  final String url;
  final Map<String, String>? headers;

  const ResolvedImageRequest({required this.url, this.headers});
}

class StorageHelper {
  static final _client = Supabase.instance.client;
  static final Map<String, _CacheEntry> _cache = {};
  static final Map<String, DateTime> _missingUntil = {};
  static final Map<String, int> _cacheBustVersions = {};
  static final Set<String> _knownImageCacheKeys = {};
  static const String _bucket = 'profile-photos';
  static const Duration _missingTtl = Duration(minutes: 10);

  /// Persistent (local-storage) layer for signed URLs.
  /// Memory [_cache] is fast but emptied on restart; SharedPreferences
  /// survives restarts so photos resolve instantly on UI startup without
  /// waiting for `createSignedUrl` network calls. Entries store expiry and
  /// are only reused while still valid (>15s left).
  static const String _persistPrefix = 'signed_url_v1:';
  static bool _persistWarmupStarted = false;
  static Future<void>? _persistWarmupFuture;

  /// Removes signed URL state when the current account session ends.
  static Future<void> clearSessionCache() async {
    _cache.clear();
    _missingUntil.clear();
    if (!kIsWeb) {
      for (final raw in _knownImageCacheKeys) {
        final version = _cacheBustVersions[raw] ?? 0;
        final key = _sanitizeCacheKey(raw) + (version > 0 ? '_v$version' : '');
        await clearDiskCachedImage(key);
      }
    }
    _knownImageCacheKeys.clear();
    _cacheBustVersions.clear();
    _persistWarmupStarted = false;
    _persistWarmupFuture = null;
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs
        .getKeys()
        .where((key) => key.startsWith(_persistPrefix))
        .toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }

  static String _persistKey(String cacheKey) => '$_persistPrefix$cacheKey';

  static void _persistUrlInBackground(
    String cacheKey,
    String url,
    DateTime expiresAt,
  ) {
    if (cacheKey.isEmpty || url.isEmpty) return;
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final payload = jsonEncode({
          'url': url,
          'exp': expiresAt.millisecondsSinceEpoch,
        });
        await prefs.setString(_persistKey(cacheKey), payload);
      } catch (_) {}
    }());
  }

  static Future<String?> _loadPersistedUrl(String cacheKey) async {
    if (cacheKey.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_persistKey(cacheKey));
      if (raw == null || raw.isEmpty) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final url = (data['url'] ?? '').toString();
      final expMillis = int.tryParse((data['exp'] ?? '').toString()) ?? 0;
      if (url.isEmpty || expMillis <= 0) return null;
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        expMillis,
        isUtc: false,
      );
      // Require substantial validity left so the image load finishes.
      if (!expiresAt.isAfter(DateTime.now().add(const Duration(seconds: 15)))) {
        return null;
      }
      // Promote to memory so sync getCachedUrl hits next time.
      _cache[cacheKey] = _CacheEntry(url, expiresAt);
      return url;
    } catch (_) {
      return null;
    }
  }

  /// Warm memory from local storage at startup (fire-and-forget).
  /// Call once during bootstrap so the first photo resolves without network.
  static Future<void> warmUpPersistedUrlCache() {
    if (_persistWarmupFuture != null) return _persistWarmupFuture!;
    _persistWarmupFuture = () async {
      if (_persistWarmupStarted) return;
      _persistWarmupStarted = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        final keys = prefs
            .getKeys()
            .where((k) => k.startsWith(_persistPrefix))
            .toList();
        final now = DateTime.now();
        var loaded = 0;
        for (final fullKey in keys) {
          if (loaded >= 200) break;
          try {
            final raw = prefs.getString(fullKey);
            if (raw == null || raw.isEmpty) continue;
            final data = jsonDecode(raw) as Map<String, dynamic>;
            final url = (data['url'] ?? '').toString();
            final expMillis = int.tryParse((data['exp'] ?? '').toString()) ?? 0;
            if (url.isEmpty || expMillis <= 0) continue;
            final expiresAt = DateTime.fromMillisecondsSinceEpoch(expMillis);
            if (!expiresAt.isAfter(now.add(const Duration(seconds: 15)))) {
              // Evict expired persisted entries lazily.
              try {
                await prefs.remove(fullKey);
              } catch (_) {}
              continue;
            }
            final cacheKey = fullKey.substring(_persistPrefix.length);
            if (cacheKey.isEmpty) continue;
            // Don't overwrite a fresher memory entry.
            final existing = _cache[cacheKey];
            if (existing != null && existing.expiresAt.isAfter(expiresAt)) {
              continue;
            }
            _cache[cacheKey] = _CacheEntry(url, expiresAt);
            loaded++;
          } catch (_) {}
        }
        if (kDebugMode && loaded > 0) {
          debugPrint('🖼️ StorageHelper: warmed $loaded persisted signed URLs');
        }
      } catch (_) {}
    }();
    return _persistWarmupFuture!;
  }

  static Future<void> _evictPersisted(String cacheKey) async {
    if (cacheKey.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_persistKey(cacheKey));
    } catch (_) {}
  }

  /// Cache keys used for the persistent signed-URL lookup, mirroring
  /// [getCachedUrl] candidate order (memory key first).
  static String? _persistLookupKey(String urlOrObjectPath, {String? bucket}) {
    final normalized = _normalizeToObjectPath(urlOrObjectPath);
    if (normalized != null && normalized.isNotEmpty) {
      // Default-bucket memory key is the bare object path; bucket-specific
      // callers also populate '<bucket>:<path>'.
      if (bucket != null && bucket.trim().isNotEmpty) {
        return '${bucket.trim()}:$normalized';
      }
      return normalized;
    }
    if (urlOrObjectPath.isNotEmpty) return urlOrObjectPath;
    return null;
  }

  static bool get canCreateSignedUrls {
    final token = _client.auth.currentSession?.accessToken;
    return token != null && token.isNotEmpty;
  }

  /// Return true if input looks like a signed URL (has token or AWS-like signature parameters).
  static bool _looksLikeSignedUrl(String urlOrPath) {
    try {
      final uri = Uri.parse(urlOrPath);
      if (uri.queryParameters.containsKey('token')) return true;
      // Common presigned URL markers (aws style)
      if (uri.query.isNotEmpty &&
          (uri.query.contains('X-Amz-') ||
              uri.query.contains('X-Amz-Signature'))) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  static String _missingKey(String objectPath, {String? bucket}) {
    final b = (bucket ?? _bucket).trim();
    return '$b:$objectPath';
  }

  static bool _isKnownMissing(String objectPath, {String? bucket}) {
    final key = _missingKey(objectPath, bucket: bucket);
    final until = _missingUntil[key];
    if (until == null) return false;
    if (until.isAfter(DateTime.now())) return true;
    _missingUntil.remove(key);
    return false;
  }

  static void _markMissing(String objectPath, {String? bucket}) {
    final key = _missingKey(objectPath, bucket: bucket);
    _missingUntil[key] = DateTime.now().add(_missingTtl);
    // Auto-heal: if this is a profile photo belonging to the current user,
    // remove the stale reference from the user's photos array in the DB.
    _tryAutoHealProfilePhoto(objectPath, bucket: bucket);
  }

  /// Auto-heal: when a profile photo is confirmed missing in storage,
  /// remove its path from the owner's `photos` column so the stale reference
  /// doesn't keep triggering errors. Only fires for the current user's own
  /// photos (cannot heal other users' data).
  static void _tryAutoHealProfilePhoto(String objectPath, {String? bucket}) {
    if (bucket != null && bucket != _bucket) return;
    final slashIdx = objectPath.indexOf('/');
    if (slashIdx <= 0) return;
    final photoUserId = objectPath.substring(0, slashIdx);
    final currentUserId = _client.auth.currentUser?.id;
    if (currentUserId == null || photoUserId != currentUserId) return;
    unawaited(_removeMissingPhotoFromDb(objectPath, currentUserId));
  }

  /// Perform the DB cleanup: fetch the user's current photos array, remove
  /// the missing path, and write back to Supabase. Photos live on
  /// `user_profiles` (the `users.photos` column was dropped by the
  /// 2026-07-10 migration — updating it silently failed, so stale
  /// references were never healed).
  static Future<void> _removeMissingPhotoFromDb(
    String objectPath,
    String userId,
  ) async {
    try {
      final response = await _client
          .from('user_profiles')
          .select('photos')
          .eq('user_id', userId)
          .single();
      final raw = response['photos'];
      if (raw == null) return;
      final List<String> photos;
      if (raw is List) {
        photos = raw.map((e) => e.toString()).toList();
      } else {
        return;
      }
      if (!photos.contains(objectPath)) return;
      final cleaned = List<String>.from(photos)..remove(objectPath);
      if (cleaned.length == photos.length) return;
      await _client
          .from('user_profiles')
          .update({'photos': cleaned})
          .eq('user_id', userId);
      // Evict local caches so SignedImage doesn't re-request the same object
      _cache.remove(objectPath);
      _missingUntil.remove(_missingKey(objectPath, bucket: _bucket));
      debugPrint('Auto-heal: removed missing photo');
    } catch (e) {
      debugPrint('Auto-heal: could not remove missing photo $objectPath: $e');
    }
  }

  /// Public check: is the given source (object path, URL, or bucket-prefixed path)
  /// known to be missing in storage?
  static bool isKnownMissing(String urlOrObjectPath, {String? bucket}) {
    if (urlOrObjectPath.isEmpty) return false;
    final normalized = _normalizeToObjectPath(urlOrObjectPath);
    if (normalized == null || normalized.isEmpty) return false;
    return _isKnownMissing(normalized, bucket: bucket);
  }

  static bool _looksLikeMissingError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('object not found') ||
        msg.contains('not found') ||
        msg.contains('status code 404') ||
        msg.contains('statuscode: 404');
  }

  /// Try to extract an object path (relative to the bucket) from a full Supabase public URL.
  /// Handles multiple URL shapes by finding the bucket path segment then joining the remainder.
  /// Example:
  ///  - https://.../storage/v1/object/public/profile-photos/userId/file.jpg -> userId/file.jpg
  ///  - https://.../storage/v1/object/public/profile-photos/folder/sub/file.jpg -> folder/sub/file.jpg
  static String? _extractObjectPathFromUrl(String input) {
    try {
      final uri = Uri.parse(input);
      // Look for the bucket segment in the path segments
      final segments = uri.pathSegments;
      if (segments.isEmpty) return null;

      // Find the first index of the bucket name in the segments (case sensitive match)
      final idx = segments.indexOf(_bucket);
      if (idx >= 0 && idx < segments.length - 1) {
        final remainder = segments.sublist(idx + 1);
        if (remainder.isEmpty) return '';
        return remainder.join('/');
      }

      // Fallback: some environments may include '/object/public/<bucket>/...' or '/object/<bucket>/...'
      // Search for 'public' segment followed by bucket
      final pubIdx = segments.indexOf('public');
      if (pubIdx >= 0 &&
          pubIdx + 1 < segments.length &&
          segments[pubIdx + 1] == _bucket &&
          pubIdx + 2 < segments.length) {
        return segments.sublist(pubIdx + 2).join('/');
      }

      // Not a recognized Supabase storage URL shape
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Normalize an objectPath input:
  /// - If input is a full URL, attempt to extract objectPath.
  /// - If input contains the bucket prefix (profile-photos/...), strip it.
  /// - Return null if normalization fails.
  static String? _normalizeToObjectPath(String input) {
    if (input.isEmpty) return null;

    // If it's a full URL, try to extract
    if (input.startsWith('http://') || input.startsWith('https://')) {
      final extracted = _extractObjectPathFromUrl(input);
      if (extracted != null && extracted.isNotEmpty) return extracted;
      // If extraction returned empty string or null, we can't normalize - return null to signal failure.
      if (extracted == '') return '';
      return null;
    }

    // Remove any leading slashes
    var candidate = input.startsWith('/') ? input.substring(1) : input;

    // If candidate starts with the bucket prefix, strip it
    if (candidate.startsWith('$_bucket/')) {
      candidate = candidate.substring('$_bucket/'.length);
    }

    return candidate;
  }

  /// Returns a stable cache key for an object source (objectPath or URL).
  ///
  /// This is intended for disk image caching so that:
  /// - Different signed URLs (different tokens) still map to the same cached bytes.
  /// - Public URLs map to the same key as the object path.
  ///
  /// If normalization fails, we fall back to a URL without query/fragment (when possible).
  static String cacheKeyForSource(String urlOrPath) {
    if (urlOrPath.isEmpty) return '';
    final raw = _cacheBaseKeyRaw(urlOrPath);
    if (raw.isEmpty) return '';
    _knownImageCacheKeys.add(raw);
    final baseKey = _sanitizeCacheKey(raw);
    final version = _cacheBustVersions[raw] ?? 0;
    if (version <= 0) return baseKey;
    return '${baseKey}_v$version';
  }

  static String _cacheBaseKeyRaw(String urlOrPath) {
    final normalized = _normalizeToObjectPath(urlOrPath);
    if (normalized != null && normalized.isNotEmpty) {
      return normalized;
    }

    try {
      final uri = Uri.parse(urlOrPath);
      final withoutQuery = uri.replace(query: '', fragment: '');
      final s = withoutQuery.toString();
      return s.isNotEmpty ? s : urlOrPath;
    } catch (_) {
      return urlOrPath;
    }
  }

  static void evictImageCache(String urlOrPath) {
    if (urlOrPath.isEmpty) return;
    final raw = _cacheBaseKeyRaw(urlOrPath);
    if (raw.isEmpty) {
      evict(urlOrPath);
      return;
    }
    final oldVersion = _cacheBustVersions[raw] ?? 0;
    developer.log(
      '🧹 Evict image cache: raw=$raw, oldVersion=$oldVersion',
      name: 'MatchMeTrace',
    );
    final oldKey =
        _sanitizeCacheKey(raw) + (oldVersion > 0 ? '_v$oldVersion' : '');
    // Always evict the persisted byte cache (the layer SignedImage paints
    // from) so a photo change takes effect on every platform.
    unawaited(
      OfflineImageCache.instance.evict(oldKey).catchError((Object error) {
        debugPrint('Could not evict cached image bytes: $error');
      }),
    );
    if (!kIsWeb) {
      // Legacy temp-dir entries from the old ExtendedImage pipeline.
      unawaited(clearDiskCachedImage(oldKey));
    }
    evict(urlOrPath);
    _cacheBustVersions[raw] = oldVersion + 1;
    developer.log(
      '🧹 Evict image cache: newVersion=${_cacheBustVersions[raw]}',
      name: 'MatchMeTrace',
    );
  }

  /// Download the image bytes for a resolved URL and persist them into the
  /// encrypted OfflineImageCache (the layer SignedImage paints from on every
  /// platform). Deduplicates concurrent fetches of the same URL so widgets
  /// and the startup warmer share a single request.
  ///
  /// Entries larger than 1MB (full-screen originals) are returned but not
  /// persisted, so the byte cache stays avatar/chat-photo sized.
  static final Map<String, Future<Uint8List?>> _imageFetches = {};

  static Future<Uint8List?> fetchImageBytesFromUrl(
    String url, {
    Map<String, String>? headers,
    String? cacheKey,
    String? objectPath,
  }) {
    if (url.trim().isEmpty) return Future<Uint8List?>.value();
    final pending = _imageFetches[url];
    if (pending != null) return pending;
    final future = _fetchImageBytesImpl(
      url,
      headers: headers,
      cacheKey: cacheKey,
      objectPath: objectPath,
    );
    _imageFetches[url] = future;
    return future.whenComplete(() => _imageFetches.remove(url));
  }

  static Future<Uint8List?> _fetchImageBytesImpl(
    String url, {
    Map<String, String>? headers,
    String? cacheKey,
    String? objectPath,
  }) async {
    try {
      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        // A 404 from an *authorized* request (signed URL token or bearer
        // header) proves the object is gone — remember it so the renderer
        // stops showing a broken-image tile and the auto-heal can drop the
        // stale reference. A 404 from an unauthenticated public URL means
        // nothing for a private bucket, so it must never mark the object
        // missing.
        if (response.statusCode == 404 &&
            objectPath != null &&
            objectPath.isNotEmpty &&
            _isAuthorizedImageRequest(url, headers)) {
          _markMissing(objectPath);
        }
        return null;
      }
      final bytes = Uint8List.fromList(response.bodyBytes);
      if (cacheKey != null && cacheKey.isNotEmpty && bytes.length <= 1024 * 1024) {
        await OfflineImageCache.instance.write(cacheKey, bytes);
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Whether the request that fetched [url] carried credentials (signed-URL
  /// token or Authorization header), i.e. a 404 response is authoritative.
  static bool _isAuthorizedImageRequest(String url, Map<String, String>? headers) {
    if (headers != null) {
      for (final key in headers.keys) {
        if (key.toLowerCase() == 'authorization') return true;
      }
    }
    try {
      return Uri.parse(url).queryParameters.containsKey('token');
    } catch (_) {
      return false;
    }
  }

  static Future<void> prefetchImageSource(
    String urlOrObjectPath, {
    String? bucket,
  }) async {
    if (urlOrObjectPath.trim().isEmpty) return;
    try {
      final cacheKey = cacheKeyForSource(urlOrObjectPath);
      if (cacheKey.isNotEmpty) {
        final existing = await OfflineImageCache.instance.read(cacheKey);
        if (existing != null && existing.isNotEmpty) return;
      }
      final request = await resolveImageRequest(
        urlOrObjectPath,
        bucket: bucket,
      );
      if (request == null || request.url.isEmpty) return;
      await fetchImageBytesFromUrl(
        request.url,
        headers: request.headers,
        cacheKey: cacheKey.isNotEmpty ? cacheKey : request.url,
        objectPath: urlOrObjectPath,
      );
    } catch (_) {}
  }

  /// Maximum number of images prefetched concurrently. Each prefetch can cost
  /// a signed-URL round trip plus a download; running them one-by-one made a
  /// 7-avatar warm take ~16s on a slow network. A small cap keeps the wall
  /// clock low without bursting the connection.
  static const int _prefetchConcurrency = 4;

  /// Prefetches [sources] into the OfflineImageCache, up to
  /// [_prefetchConcurrency] at a time. Individual failures are swallowed
  /// (best-effort), and one slow/hung image cannot stall the whole batch past
  /// the per-source budget.
  static Future<void> prefetchImageSources(
    Iterable<String> sources, {
    String? bucket,
  }) async {
    final uniqueSources = <String>{};
    for (final source in sources) {
      final trimmed = source.trim();
      if (trimmed.isEmpty) continue;
      uniqueSources.add(trimmed);
    }
    if (uniqueSources.isEmpty) return;

    final it = uniqueSources.iterator;
    Future<void> worker() async {
      while (true) {
        String source;
        if (!it.moveNext()) return;
        source = it.current;
        try {
          await prefetchImageSource(source, bucket: bucket).timeout(
            const Duration(seconds: 12),
          );
        } on TimeoutException {
          // Skip this image; let the rest of the batch continue.
        } catch (_) {}
      }
    }

    final workers = List<Future<void>>.generate(
      _prefetchConcurrency < uniqueSources.length
          ? _prefetchConcurrency
          : uniqueSources.length,
      (_) => worker(),
    );
    await Future.wait(workers);
  }

  /// Make a string safe for use as a disk cache key / filename.
  ///
  /// `extended_image` uses the cache key to create files under the cache directory.
  /// If the key contains path separators like `/`, it can be treated as subdirectories
  /// and cause `PathNotFoundException` when those folders don't exist.
  static String _sanitizeCacheKey(String raw) {
    if (raw.isEmpty) return '';

    // Replace anything that could be interpreted as a path or invalid filename char.
    // Keep alnum plus a few safe chars for readability.
    final sanitized = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

    // Avoid pathological keys.
    if (sanitized.isEmpty) return 'img';
    if (sanitized.length > 180) {
      // Keep suffix for uniqueness; still deterministic.
      return sanitized.substring(sanitized.length - 180);
    }
    return sanitized;
  }

  /// Construct a public URL for an object path
  static String? constructPublicUrl(String objectPath) {
    final normalized = _normalizeToObjectPath(objectPath);
    if (normalized == null || normalized.isEmpty) return null;
    // Use the actual Supabase client URL from the auth client
    // The storage client doesn't expose the base URL directly, so we get it from the main client
    final client = Supabase.instance.client;
    final projectUrl = client.storage
        .from(_bucket)
        .getPublicUrl('')
        .split('/storage/v1/object/public')[0];
    return '$projectUrl/storage/v1/object/public/$_bucket/$normalized';
  }

  static String? buildPublicObjectUrl(
    String urlOrObjectPath, {
    String? bucket,
  }) {
    if (urlOrObjectPath.isEmpty) return null;
    final normalized = _normalizeToObjectPath(urlOrObjectPath);
    if (normalized == null || normalized.isEmpty) {
      if (urlOrObjectPath.startsWith('http://') ||
          urlOrObjectPath.startsWith('https://')) {
        return urlOrObjectPath;
      }
      return null;
    }

    final bucketName = (bucket ?? _bucket).trim();
    if (bucketName.isEmpty) return null;

    try {
      return _client.storage.from(bucketName).getPublicUrl(normalized);
    } catch (_) {
      if (bucketName == _bucket) {
        return constructPublicUrl(normalized);
      }
      return null;
    }
  }

  static Map<String, String>? buildAuthHeaders() {
    final token = _client.auth.currentSession?.accessToken;
    if (token == null || token.trim().isEmpty) return null;
    final headers = <String, String>{'Authorization': 'Bearer $token'};
    final apiKey = _client.headers['apikey'];
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      headers['apikey'] = apiKey;
    }
    return headers;
  }

  static String? buildAuthenticatedObjectUrl(
    String urlOrObjectPath, {
    String? bucket,
  }) {
    final normalized = _normalizeToObjectPath(urlOrObjectPath);
    if (normalized == null || normalized.trim().isEmpty) return null;
    final b = (bucket ?? _bucket).trim();
    if (b.isEmpty) return null;
    final supabaseUrl = runtimeSupabaseUrl;
    if (supabaseUrl == null || supabaseUrl.isEmpty) return null;
    return '$supabaseUrl/storage/v1/object/$b/$normalized';
  }

  static Future<ResolvedImageRequest?> resolveImageRequest(
    String urlOrObjectPath, {
    String? bucket,
    int? ttlSeconds,
  }) async {
    ttlSeconds ??= await (() async {
      try {
        return await AppConfigService().getInt(
          'profile.signed_url_ttl_seconds',
          defaultValue: 3600,
        );
      } catch (e) {
        return 3600;
      }
    })();
    final source = urlOrObjectPath.trim();
    if (source.isEmpty) return null;

    if (_looksLikeSignedUrl(source)) {
      return ResolvedImageRequest(url: source);
    }

    final cachedUrl = getCachedUrl(source, bucket: bucket);
    if (cachedUrl != null && cachedUrl.isNotEmpty) {
      return ResolvedImageRequest(url: cachedUrl);
    }

    // Local-storage layer (survives restarts): reuse a still-valid persisted
    // signed URL instantly so photos display on UI startup without network.
    try {
      final persistedKey = _persistLookupKey(source, bucket: bucket);
      if (persistedKey != null && persistedKey.isNotEmpty) {
        final persisted = await _loadPersistedUrl(persistedKey);
        if (persisted != null && persisted.isNotEmpty) {
          return ResolvedImageRequest(url: persisted);
        }
      }
    } catch (_) {}

    final signedUrl = bucket != null
        ? await getSignedUrlFromBucket(source, bucket, ttlSeconds: ttlSeconds)
        : await getSignedUrl(source, ttlSeconds: ttlSeconds);
    if (signedUrl != null && signedUrl.isNotEmpty) {
      return ResolvedImageRequest(url: signedUrl);
    }

    if (!kIsWeb) {
      final headers = buildAuthHeaders();
      final authenticatedUrl = headers != null
          ? buildAuthenticatedObjectUrl(source, bucket: bucket)
          : null;
      if (authenticatedUrl != null &&
          authenticatedUrl.isNotEmpty &&
          headers != null &&
          headers.isNotEmpty) {
        return ResolvedImageRequest(url: authenticatedUrl, headers: headers);
      }
    }

    // Don't fall back to public URL if this object is known missing
    if (!isKnownMissing(source, bucket: bucket)) {
      final publicUrl = buildPublicObjectUrl(source, bucket: bucket);
      if (publicUrl != null && publicUrl.isNotEmpty) {
        return ResolvedImageRequest(url: publicUrl);
      }
    }

    if (source.startsWith('http://') || source.startsWith('https://')) {
      return ResolvedImageRequest(url: source);
    }

    return null;
  }

  /// First tries to construct a public URL if the bucket is public.
  /// Falls back to signed URL if public access fails.
  /// ttlSeconds defaults to 3600 (1 hour).
  /// Accepts either a plain objectPath or a Supabase public object URL; if a full signed URL
  /// is passed in it will be returned unchanged.
  /// Returns null on failure (object missing, network error).
  static Future<String?> getSignedUrl(
    String urlOrObjectPath, {
    int? ttlSeconds,
  }) async {
    ttlSeconds ??= await (() async {
      try {
        return await AppConfigService().getInt(
          'profile.signed_url_ttl_seconds',
          defaultValue: 3600,
        );
      } catch (e) {
        return 3600;
      }
    })();
    if (urlOrObjectPath.isEmpty) return null;

    // If it's already a signed URL, return as-is.
    if (_looksLikeSignedUrl(urlOrObjectPath)) {
      return urlOrObjectPath;
    }

    // Normalize input to objectPath (relative to bucket)
    final normalized = _normalizeToObjectPath(urlOrObjectPath);
    if (normalized == null) {
      // Could not normalize the input into an objectPath.
      return null;
    }
    // normalized may be '' if the URL pointed to the bucket root; treat as failure.
    if (normalized.isEmpty) {
      return null;
    }

    final objectPath = normalized;

    // Return cached URL if not expired and has substantial time left (e.g., > 15s)
    final now = DateTime.now();
    if (_isKnownMissing(objectPath, bucket: _bucket)) {
      return null;
    }
    final cached = _cache[objectPath];
    if (cached != null &&
        cached.expiresAt.isAfter(now.add(const Duration(seconds: 15)))) {
      return cached.url;
    }
    // Local storage (persisted across restarts) — instant display on startup.
    try {
      final persisted = await _loadPersistedUrl(objectPath);
      if (persisted != null && persisted.isNotEmpty) {
        return persisted;
      }
    } catch (_) {}

    if (!canCreateSignedUrls) {
      return null;
    }

    // Skip Supabase calls when paused (offline)
    if (shouldSkipSupabaseCalls()) {
      return null;
    }

    // Use signed URLs for authenticated access only
    // This ensures profile photos are only accessible to logged-in users
    try {
      // A hung createSignedUrl used to stall its whole prefetch batch (and any
      // caller awaiting this resolve) with no bound. Cap it so a dead backend
      // fails fast and the caller can fall back to cache.
      final dynamic resp = await _client.storage
          .from(_bucket)
          .createSignedUrl(objectPath, ttlSeconds)
          .timeout(const Duration(seconds: 8));

      String? url;

      if (resp == null) {
        url = null;
      } else if (resp is String) {
        url = resp;
      } else if (resp is Map) {
        url = (resp['signedUrl'] ?? resp['signed_url'] ?? resp['signedurl'])
            ?.toString();
        if (url == null && resp.containsKey('data')) {
          final d = resp['data'];
          if (d is Map) url = (d['signedUrl'] ?? d['signed_url'])?.toString();
        }
      } else {
        // some SDKs return object with .signedUrl
        try {
          final maybe =
              (resp as dynamic).signedUrl ?? (resp as dynamic).data?.signedUrl;
          if (maybe is String) url = maybe;
        } catch (_) {}
      }

      if (url == null) {
        debugPrint('createSignedUrl returned null for $objectPath');
        return null;
      }

      final expiresAt = now.add(Duration(seconds: ttlSeconds));
      _cache[objectPath] = _CacheEntry(url, expiresAt);
      // Persist to local storage (memory + disk) for instant startup.
      _persistUrlInBackground(objectPath, url, expiresAt);

      return url;
    } on StorageException catch (e) {
      // Explicitly handle StorageException (from supabase client) to log 404 / not_found and auth errors
      final msg = e.message.toLowerCase();
      final cleanMsg = e.message.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      debugPrint(
        'StorageException creating signed URL for $objectPath: $cleanMsg',
      );
      if (msg.contains('401') || msg.contains('403')) {
        debugPrint(
          '⚠️ Storage signing failed: Authentication/Authorization error - check JWT validity',
        );
      }
      if (_looksLikeMissingError(e)) {
        _markMissing(objectPath, bucket: _bucket);
      }
      return null;
    } catch (e) {
      // Suppress error logging for expected offline failures
      if (!isExpectedOfflineFailure(e)) {
        debugPrint('Error creating signed URL for $objectPath: $e');
      }
      if (_looksLikeMissingError(e)) {
        _markMissing(objectPath, bucket: _bucket);
      }
      return null;
    }

    // Note: If public access fails, you could uncomment the code below to fall back to signed URLs
    /*
    try {
      final dynamic resp = await _client.storage.from(_bucket).createSignedUrl(objectPath, ttlSeconds);

      String? url;

      if (resp == null) {
        url = null;
      } else if (resp is String) {
        url = resp;
      } else if (resp is Map) {
        url = (resp['signedUrl'] ?? resp['signed_url'] ?? resp['signedurl'])?.toString();
        if (url == null && resp.containsKey('data')) {
          final d = resp['data'];
          if (d is Map) url = (d['signedUrl'] ?? d['signed_url'])?.toString();
        }
      } else {
        // some SDKs return object with .signedUrl
        try {
          final maybe = (resp as dynamic).signedUrl ?? (resp as dynamic).data?.signedUrl;
          if (maybe is String) url = maybe;
        } catch (_) {}
      }

      if (url == null) {
        return null;
      }

      final expiresAt = now.add(Duration(seconds: ttlSeconds));
      _cache[objectPath] = _CacheEntry(url, expiresAt);

      return url;
    } on StorageException {
      // Explicitly handle StorageException (from supabase client) to log 404 / not_found
      return null;
    } catch (e) {
      return null;
    }
    */
  }

  /// Return a signed URL for the given object path from a specific bucket, or null if not found.
  static Future<String?> getSignedUrlFromBucket(
    String urlOrObjectPath,
    String bucketName, {
    int ttlSeconds = 3600,
  }) async {
    if (urlOrObjectPath.isEmpty) return null;

    // If it's already a signed URL, return as-is.
    if (_looksLikeSignedUrl(urlOrObjectPath)) {
      return urlOrObjectPath;
    }

    // Normalize input to objectPath (relative to bucket)
    final normalized = _normalizeToObjectPath(urlOrObjectPath);
    if (normalized == null) {
      // Could not normalize the input into an objectPath.
      return null;
    }
    // normalized may be '' if the URL pointed to the bucket root; treat as failure.
    if (normalized.isEmpty) {
      return null;
    }

    final objectPath = normalized;

    // Return cached URL if not expired and has substantial time left (e.g., > 15s)
    final now = DateTime.now();
    final cacheKey = '$bucketName:$objectPath';
    if (_isKnownMissing(objectPath, bucket: bucketName)) {
      return null;
    }
    final cached = _cache[cacheKey];
    if (cached != null &&
        cached.expiresAt.isAfter(now.add(const Duration(seconds: 15)))) {
      return cached.url;
    }
    // Local storage (persisted across restarts) — instant display on startup.
    try {
      final persisted = await _loadPersistedUrl(cacheKey);
      if (persisted != null && persisted.isNotEmpty) {
        return persisted;
      }
    } catch (_) {}

    if (!canCreateSignedUrls) {
      return null;
    }

    // Skip Supabase calls when paused (offline)
    if (shouldSkipSupabaseCalls()) {
      return null;
    }

    // Use signed URLs for authenticated access only
    try {
      final dynamic resp = await _client.storage
          .from(bucketName)
          .createSignedUrl(objectPath, ttlSeconds);

      String? url;

      if (resp == null) {
        url = null;
      } else if (resp is String) {
        url = resp;
      } else if (resp is Map) {
        url = (resp['signedUrl'] ?? resp['signed_url'] ?? resp['signedurl'])
            ?.toString();
        if (url == null && resp.containsKey('data')) {
          final d = resp['data'];
          if (d is Map) url = (d['signedUrl'] ?? d['signed_url'])?.toString();
        }
      } else {
        // some SDKs return object with .signedUrl
        try {
          final maybe =
              (resp as dynamic).signedUrl ?? (resp as dynamic).data?.signedUrl;
          if (maybe is String) url = maybe;
        } catch (_) {}
      }

      if (url == null) {
        debugPrint(
          'createSignedUrl returned null for $objectPath in bucket $bucketName',
        );
        return null;
      }

      // Cache the signed URL (memory + local storage for instant startup).
      final bucketExpiresAt = now.add(
        Duration(seconds: ttlSeconds - 60),
      ); // Expire 1 minute early
      _cache[cacheKey] = _CacheEntry(url, bucketExpiresAt);
      _persistUrlInBackground(cacheKey, url, bucketExpiresAt);
      return url;
    } on StorageException catch (e) {
      final msg = e.message.toLowerCase();
      final cleanMsg = e.message.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      debugPrint(
        'StorageException creating signed URL for $objectPath in bucket $bucketName: $cleanMsg',
      );
      if (msg.contains('401') || msg.contains('403')) {
        debugPrint(
          '⚠️ Storage signing failed: Authentication/Authorization error - check JWT validity',
        );
      }
      if (_looksLikeMissingError(e)) {
        _markMissing(objectPath, bucket: bucketName);
        return null;
      }
      // Try public URL as fallback for public buckets
      try {
        final publicUrl = _client.storage
            .from(bucketName)
            .getPublicUrl(objectPath);
        return publicUrl;
      } catch (_) {
        return null;
      }
    } catch (e) {
      debugPrint(
        'createSignedUrl failed for $objectPath in bucket $bucketName: $e',
      );
      if (_looksLikeMissingError(e)) {
        _markMissing(objectPath, bucket: bucketName);
        return null;
      }
      // Try public URL as fallback for public buckets
      try {
        final publicUrl = _client.storage
            .from(bucketName)
            .getPublicUrl(objectPath);
        return publicUrl;
      } catch (_) {
        return null;
      }
    }
  }

  /// Clear cache for an objectPath (call after delete/replace)
  static void evict(String objectPathOrUrl) {
    if (objectPathOrUrl.isEmpty) return;
    // Try normalize; if we get an objectPath, evict that key
    final normalized = _normalizeToObjectPath(objectPathOrUrl);
    if (normalized != null && normalized.isNotEmpty) {
      _cache.remove(normalized);
      _cache.remove('$_bucket:$normalized');
      _missingUntil.remove(_missingKey(normalized, bucket: _bucket));
      // Also evict persisted local-storage entries (memory + disk).
      unawaited(_evictPersisted(normalized));
      unawaited(_evictPersisted('$_bucket:$normalized'));
      return;
    }
    // Otherwise remove the raw key if present
    _cache.remove(objectPathOrUrl);
    unawaited(_evictPersisted(objectPathOrUrl));
  }

  /// Delete an object from the configured storage bucket.
  /// Accepts either an object path ("userId/123.jpg"), a bucket-prefixed
  /// path ("profile-photos/userId/123.jpg"), or a full Supabase public URL.
  /// Returns true if the delete call was attempted and did not throw.
  /// Note: this is a best-effort operation; failures return false.
  static Future<bool> deleteObject(String urlOrPath) async {
    try {
      final normalized = _normalizeToObjectPath(urlOrPath);
      if (normalized == null || normalized.isEmpty) return false;
      try {
        await _client.storage.from(_bucket).remove([normalized]);
      } catch (_) {
        return false;
      }
      // Evict any cached signed url for the deleted object (memory + disk).
      _cache.remove(normalized);
      unawaited(_evictPersisted(normalized));
      unawaited(_evictPersisted('$_bucket:$normalized'));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Optional helper: get immediate cached url or null (no network)
  static String? getCachedUrl(String objectPath, {String? bucket}) {
    final candidates = <String>{};
    final normalized = _normalizeToObjectPath(objectPath);
    if (normalized != null && normalized.isNotEmpty) {
      candidates.add(normalized);
      candidates.add('${bucket ?? _bucket}:$normalized');
    }
    if (objectPath.isNotEmpty) {
      candidates.add(objectPath);
      if (bucket != null) {
        candidates.add('$bucket:$objectPath');
      }
    }

    for (final key in candidates) {
      final cached = _cache[key];
      if (cached == null) continue;
      if (cached.expiresAt.isAfter(DateTime.now())) return cached.url;
      _cache.remove(key);
    }
    return null;
  }
}
