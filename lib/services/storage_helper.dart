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
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _CacheEntry {
  final String url;
  final DateTime expiresAt;
  _CacheEntry(this.url, this.expiresAt);
}

class StorageHelper {
  static final _client = Supabase.instance.client;
  static final Map<String, _CacheEntry> _cache = {};
  static const String _bucket = 'profile-photos';

  /// Return true if input looks like a signed URL (has token or AWS-like signature parameters).
  static bool _looksLikeSignedUrl(String urlOrPath) {
    try {
      final uri = Uri.parse(urlOrPath);
      if (uri.queryParameters.containsKey('token')) return true;
      // Common presigned URL markers (aws style)
      if (uri.query.isNotEmpty && (uri.query.contains('X-Amz-') || uri.query.contains('X-Amz-Signature'))) return true;
    } catch (_) {}
    return false;
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
      if (pubIdx >= 0 && pubIdx + 1 < segments.length && segments[pubIdx + 1] == _bucket && pubIdx + 2 < segments.length) {
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

    final normalized = _normalizeToObjectPath(urlOrPath);
    if (normalized != null && normalized.isNotEmpty) {
      return _sanitizeCacheKey(normalized);
    }

    // Fallback: strip query/fragment so token changes don't create new keys.
    try {
      final uri = Uri.parse(urlOrPath);
      final withoutQuery = uri.replace(query: '', fragment: '');
      final s = withoutQuery.toString();
      final raw = s.isNotEmpty ? s : urlOrPath;
      return _sanitizeCacheKey(raw);
    } catch (_) {
      return _sanitizeCacheKey(urlOrPath);
    }
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
    final projectUrl = 'https://vazkmvrbshxwyodentng.supabase.co';
    return '$projectUrl/storage/v1/object/public/$_bucket/$normalized';
  }
  /// First tries to construct a public URL if the bucket is public.
  /// Falls back to signed URL if public access fails.
  /// ttlSeconds defaults to 3600 (1 hour).
  /// Accepts either a plain objectPath or a Supabase public object URL; if a full signed URL
  /// is passed in it will be returned unchanged.
  /// Returns null on failure (object missing, network error).
  static Future<String?> getSignedUrl(String urlOrObjectPath, {int ttlSeconds = 3600}) async {
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
    final cached = _cache[objectPath];
    if (cached != null && cached.expiresAt.isAfter(now.add(const Duration(seconds: 15)))) {
      return cached.url;
    }

    // Use signed URLs for authenticated access only
    // This ensures profile photos are only accessible to logged-in users
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
        debugPrint('createSignedUrl returned null for $objectPath');
        return null;
      }

      final expiresAt = now.add(Duration(seconds: ttlSeconds));
      _cache[objectPath] = _CacheEntry(url, expiresAt);

      return url;
    } on StorageException catch (e) {
      // Explicitly handle StorageException (from supabase client) to log 404 / not_found
      debugPrint('StorageException creating signed URL for $objectPath: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('Error creating signed URL for $objectPath: $e');
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

  /// Clear cache for an objectPath (call after delete/replace)
  static void evict(String objectPathOrUrl) {
    if (objectPathOrUrl.isEmpty) return;
    // Try normalize; if we get an objectPath, evict that key
    final normalized = _normalizeToObjectPath(objectPathOrUrl);
    if (normalized != null && normalized.isNotEmpty) {
      _cache.remove(normalized);
      return;
    }
    // Otherwise remove the raw key if present
    _cache.remove(objectPathOrUrl);
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
      // Evict any cached signed url for the deleted object
      _cache.remove(normalized);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Optional helper: get immediate cached url or null (no network)
  static String? getCachedUrl(String objectPath) {
    final cached = _cache[objectPath];
    if (cached == null) return null;
    if (cached.expiresAt.isAfter(DateTime.now())) return cached.url;
    _cache.remove(objectPath);
    return null;
  }
}
