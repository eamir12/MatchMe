// lib/services/offline_api_cache.dart
// Encrypted, persistent read-through cache for Supabase REST responses.
//
// Every successful GET against /rest/v1 is stored here (AES-256 Hive box,
// key in Keystore/Keychain) so the next offline launch can serve the exact
// payload the server last returned: profiles, matches, chats, notifications,
// verification/rejection state, reference data, and anything else fetched
// through PostgREST. On a later successful request the entry is overwritten,
// so stale data is only ever used when the backend cannot be reached.
//
// The same bytes are kept in a bounded in-process LRU so an offline screen
// paints immediately without waiting for a Hive read.

import 'dart:convert';
import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:matchme/services/hive_encryption_service.dart';

class CachedApiResponse {
  const CachedApiResponse({
    required this.bytes,
    required this.headers,
    required this.cachedAt,
  });

  final Uint8List bytes;
  final Map<String, String> headers;
  final DateTime cachedAt;
}

class OfflineApiCache {
  OfflineApiCache._();

  static final OfflineApiCache instance = OfflineApiCache._();
  static const String _boxName = 'offline_api_cache_v1';
  static const String _entryBytesKey = 'bytes';
  static const String _entryHeadersKey = 'headers';
  static const String _entryCachedAtKey = 'cached_at';

  /// Hot cache: the most recently read/written payloads, shared per process.
  static const int _maxMemoryEntries = 64;
  static const int _maxMemoryBytes = 24 * 1024 * 1024;

  /// Bound the encrypted on-disk cache. Entries are evicted oldest-first.
  static const int _maxDiskEntries = 4000;
  static const int _maxDiskBytes = 96 * 1024 * 1024;

  /// A single REST payload larger than this is returned to the caller but not
  /// persisted; such responses are never ordinary app data.
  static const int maxPersistedEntryBytes = 8 * 1024 * 1024;

  final Map<String, CachedApiResponse> _memory = {};
  int _memoryBytes = 0;
  int? _diskBytes;

  Future<Box>? _boxFuture;

  Future<Box> _box() {
    _boxFuture ??= HiveEncryptionService.instance
        .openEncryptedBoxDynamic(_boxName)
        .catchError((Object error) {
          _boxFuture = null;
          throw StateError('Could not open the offline API cache: $error');
        });
    return _boxFuture!;
  }

  Future<void> warmup() async {
    try {
      await _box();
    } catch (_) {}
  }

  /// Headers that change what PostgREST returns for the same URL; they must be
  /// part of the cache identity (e.g. `.range()` pages use the `Range`
  /// header, and `maybeSingle()` switches the `Accept` media type).
  static const List<String> _identityHeaderNames = <String>[
    'range',
    'accept',
    'accept-profile',
    'content-profile',
  ];

  /// Stable cache identity for a request.
  ///
  /// The auth subject is part of the key so cached rows can never leak between
  /// accounts on the same device (RLS answers differ per user even for the
  /// same URL). Tokens rotate, so only the stable `sub` claim is used.
  static String buildKey({
    required String method,
    required Uri url,
    String? userId,
    Map<String, String>? headers,
  }) {
    final subject = (userId ?? '').trim();
    final buffer = StringBuffer(
      '${method.toUpperCase()} ${subject.isEmpty ? 'anon' : subject} '
      '${url.toString()}',
    );
    if (headers != null && headers.isNotEmpty) {
      final lowered = <String, String>{};
      headers.forEach((key, value) => lowered[key.toLowerCase()] = value);
      final identity = <String>[];
      for (final name in _identityHeaderNames) {
        final value = lowered[name];
        if (value != null && value.trim().isNotEmpty) {
          identity.add('$name=${value.trim()}');
        }
      }
      if (identity.isNotEmpty) {
        buffer.write(' | ${identity.join(';')}');
      }
    }
    return buffer.toString();
  }

  static String? subjectFromAuthorizationHeader(String? header) {
    final value = (header ?? '').trim();
    if (value.isEmpty) return null;
    final token = value.toLowerCase().startsWith('bearer ')
        ? value.substring(7).trim()
        : value;
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final payload = parts[1];
      final normalized = base64Url.normalize(payload);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final data = jsonDecode(decoded);
      if (data is Map) {
        final sub = data['sub']?.toString().trim();
        if (sub != null && sub.isNotEmpty) return sub;
      }
    } catch (_) {}
    return null;
  }

  CachedApiResponse? peek(String key) {
    if (key.isEmpty) return null;
    final entry = _memory.remove(key);
    if (entry == null) return null;
    _memory[key] = entry;
    return entry;
  }

  Future<CachedApiResponse?> read(String key) async {
    if (key.isEmpty) return null;
    final hot = peek(key);
    if (hot != null) return hot;
    try {
      final entry = (await _box()).get(key);
      final parsed = _decodeEntry(entry);
      if (parsed != null) _remember(key, parsed);
      return parsed;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(
    String key,
    Uint8List bytes, {
    Map<String, String>? headers,
  }) async {
    if (key.isEmpty || bytes.isEmpty) return;
    if (bytes.length > maxPersistedEntryBytes) return;
    final sanitizedHeaders = _sanitizeHeaders(headers);
    final entry = CachedApiResponse(
      bytes: bytes,
      headers: sanitizedHeaders,
      cachedAt: DateTime.now(),
    );
    _remember(key, entry);
    try {
      final box = await _box();
      await _ensureDiskBytes(box);
      final previous = box.get(key);
      final previousSize = _entrySize(previous);
      await box.put(key, <String, dynamic>{
        _entryBytesKey: bytes,
        _entryHeadersKey: sanitizedHeaders,
        _entryCachedAtKey: entry.cachedAt.millisecondsSinceEpoch,
      });
      _diskBytes = (_diskBytes ?? 0) - previousSize + bytes.length;
      await _evictDiskIfNeeded(box);
    } catch (_) {}
  }

  Future<void> clear() async {
    _memory.clear();
    _memoryBytes = 0;
    _diskBytes = 0;
    try {
      await (await _box()).clear();
    } catch (_) {}
  }

  Map<String, String> _sanitizeHeaders(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return const {};
    const dropped = <String>{
      'content-encoding',
      'content-length',
      'transfer-encoding',
      'set-cookie',
      'connection',
    };
    final result = <String, String>{};
    headers.forEach((key, value) {
      if (dropped.contains(key.toLowerCase())) return;
      result[key] = value;
    });
    return result;
  }

  CachedApiResponse? _decodeEntry(dynamic raw) {
    if (raw is! Map) return null;
    final bytesRaw = raw[_entryBytesKey];
    Uint8List? bytes;
    if (bytesRaw is Uint8List) {
      bytes = bytesRaw;
    } else if (bytesRaw is List<int>) {
      bytes = Uint8List.fromList(bytesRaw);
    }
    if (bytes == null || bytes.isEmpty) return null;
    final headersRaw = raw[_entryHeadersKey];
    final headers = <String, String>{};
    if (headersRaw is Map) {
      headersRaw.forEach((key, value) {
        headers[key.toString()] = value.toString();
      });
    }
    final cachedAtRaw = raw[_entryCachedAtKey];
    final cachedAtMillis = cachedAtRaw is int
        ? cachedAtRaw
        : int.tryParse(cachedAtRaw?.toString() ?? '') ?? 0;
    return CachedApiResponse(
      bytes: bytes,
      headers: headers,
      cachedAt: cachedAtMillis > 0
          ? DateTime.fromMillisecondsSinceEpoch(cachedAtMillis)
          : DateTime.now(),
    );
  }

  int _entrySize(dynamic raw) {
    if (raw is! Map) return 0;
    final bytesRaw = raw[_entryBytesKey];
    if (bytesRaw is Uint8List) return bytesRaw.length;
    if (bytesRaw is List<int>) return bytesRaw.length;
    return 0;
  }

  Future<void> _ensureDiskBytes(Box box) async {
    if (_diskBytes != null) return;
    var total = 0;
    for (final value in box.values) {
      total += _entrySize(value);
    }
    _diskBytes = total;
  }

  Future<void> _evictDiskIfNeeded(Box box) async {
    var total = _diskBytes ?? 0;
    if (box.length <= _maxDiskEntries && total <= _maxDiskBytes) return;
    for (final key in box.keys.toList()) {
      if (box.length <= _maxDiskEntries && total <= _maxDiskBytes) break;
      final value = box.get(key);
      total -= _entrySize(value);
      await box.delete(key);
      _memory.remove(key);
    }
    _diskBytes = total < 0 ? 0 : total;
  }

  void _remember(String key, CachedApiResponse entry) {
    final previous = _memory.remove(key);
    if (previous != null) _memoryBytes -= previous.bytes.length;
    _memory[key] = entry;
    _memoryBytes += entry.bytes.length;
    while (_memory.length > _maxMemoryEntries ||
        (_memoryBytes > _maxMemoryBytes && _memory.length > 1)) {
      final oldestKey = _memory.keys.first;
      final removed = _memory.remove(oldestKey);
      if (removed != null) _memoryBytes -= removed.bytes.length;
    }
  }
}
