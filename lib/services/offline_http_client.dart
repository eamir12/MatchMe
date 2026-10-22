// lib/services/offline_http_client.dart
// Supabase HTTP transport that makes every PostgREST read survive offline.
//
// Wired into Supabase.initialize(httpClient: ...) so auth, storage and RPC
// calls still go straight through while GET /rest/v1 responses are served
// read-through from the encrypted OfflineApiCache. Online responses always
// win and refresh the cache; stored rows are only returned when the request
// cannot reach Supabase.

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:matchme/services/offline_api_cache.dart';
import 'package:matchme/services/offline_cache_manager.dart';

class OfflineSupabaseHttpClient extends http.BaseClient {
  OfflineSupabaseHttpClient({http.Client? inner})
    : _inner = inner ?? http.Client();

  final http.Client _inner;

  static const Set<int> _cacheableGatewayFailures = {502, 503, 504};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!_isCacheable(request)) {
      return _inner.send(request);
    }

    final cacheKey = OfflineApiCache.buildKey(
      method: request.method,
      url: request.url,
      userId: OfflineApiCache.subjectFromAuthorizationHeader(
        request.headers['authorization'] ?? request.headers['Authorization'],
      ),
      headers: request.headers,
    );

    if (!OfflineCacheManager.instance.isSupabaseAvailable) {
      final cached = await OfflineApiCache.instance.read(cacheKey);
      if (cached != null) {
        return _cachedResponse(request, cached.bytes, cached.headers);
      }
    }

    http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (_) {
      final cached = await OfflineApiCache.instance.read(cacheKey);
      if (cached != null) {
        return _cachedResponse(request, cached.bytes, cached.headers);
      }
      rethrow;
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.statusCode == 204 || _isEventStream(response)) {
        return response;
      }
      final declaredLength = int.tryParse(
        response.headers['content-length'] ?? '',
      );
      if (declaredLength != null &&
          declaredLength > OfflineApiCache.maxPersistedEntryBytes) {
        return response;
      }
      late Uint8List bytes;
      try {
        bytes = await response.stream.toBytes();
      } catch (_) {
        return response;
      }
      await OfflineApiCache.instance.write(
        cacheKey,
        bytes,
        headers: response.headers,
      );
      return _cachedResponse(
        request,
        bytes,
        response.headers,
        statusCode: response.statusCode,
        reasonPhrase: response.reasonPhrase,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
      );
    }

    if (_cacheableGatewayFailures.contains(response.statusCode)) {
      final cached = await OfflineApiCache.instance.read(cacheKey);
      if (cached != null) {
        try {
          await response.stream.drain<void>();
        } catch (_) {}
        return _cachedResponse(request, cached.bytes, cached.headers);
      }
    }

    return response;
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }

  bool _isCacheable(http.BaseRequest request) {
    if (request.method.toUpperCase() != 'GET') return false;
    if (request.url.scheme != 'http' && request.url.scheme != 'https') {
      return false;
    }
    final path = request.url.path;
    if (!path.contains('/rest/v1/')) return false;
    if (path.contains('/rest/v1/rpc/')) return false;
    return true;
  }

  bool _isEventStream(http.StreamedResponse response) {
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    return contentType.contains('text/event-stream');
  }

  http.StreamedResponse _cachedResponse(
    http.BaseRequest request,
    Uint8List bytes,
    Map<String, String> headers, {
    int statusCode = 200,
    String? reasonPhrase,
    bool isRedirect = false,
    bool persistentConnection = true,
  }) {
    const droppedHeaders = <String>{
      'content-encoding',
      'content-length',
      'transfer-encoding',
      'set-cookie',
      'connection',
    };
    final safeHeaders = <String, String>{};
    headers.forEach((key, value) {
      if (droppedHeaders.contains(key.toLowerCase())) return;
      safeHeaders[key] = value;
    });
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      statusCode,
      contentLength: bytes.length,
      request: request,
      headers: safeHeaders,
      reasonPhrase: reasonPhrase,
      isRedirect: isRedirect,
      persistentConnection: persistentConnection,
    );
  }
}
