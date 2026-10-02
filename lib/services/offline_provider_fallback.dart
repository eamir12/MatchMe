// lib/services/offline_provider_fallback.dart
// Utilities to add offline fallback support to Riverpod providers

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/services/offline_cache_manager.dart';

/// Helper to check if we should use cached fallback data
bool shouldUseCachedData() {
  return offlineCacheManager.shouldUseCachedData();
}

/// Track which providers have been set as offline
/// This helps UI components know which data is from cache
class OfflineProviderState {
  final bool isFromCache;
  final DateTime? cachedAt;
  final String? cacheSource;

  OfflineProviderState({
    required this.isFromCache,
    this.cachedAt,
    this.cacheSource,
  });

  bool get isStale =>
      isFromCache &&
      cachedAt != null &&
      DateTime.now().difference(cachedAt!).inMinutes > 5;

  String get debugInfo {
    if (!isFromCache) return 'Live data';
    final age = cachedAt != null
        ? DateTime.now().difference(cachedAt!).inSeconds
        : -1;
    return 'Cached data (${age}s old, source: $cacheSource)';
  }
}

/// Wraps AsyncValue to include offline state metadata
class OfflineAwareAsyncValue<T> {
  final AsyncValue<T> asyncValue;
  final bool isFromCache;
  final DateTime? cachedAt;
  final String? cacheSource;

  OfflineAwareAsyncValue({
    required this.asyncValue,
    required this.isFromCache,
    this.cachedAt,
    this.cacheSource,
  });

  bool get hasData => asyncValue.hasValue;
  bool get hasError => asyncValue.hasError;
  bool get isLoading => asyncValue.isLoading;

  T? get valueOrNull {
    if (asyncValue.hasValue) {
      return asyncValue.asData?.value;
    }
    return null;
  }

  String get staleIndicator {
    if (!isFromCache) return '';
    final age = cachedAt != null
        ? DateTime.now().difference(cachedAt!).inSeconds
        : -1;
    return age < 0 ? '📦 Cached' : '📦 Cached (${age}s old)';
  }
}

/// Log when falling back to cached data
void logCacheFallback(String providerName, String reason) {
  print('📦 [OFFLINE FALLBACK] $providerName using cache: $reason');
}

/// Log when using live data
void logLiveData(String providerName) {
  print('🌐 [LIVE DATA] $providerName from Supabase');
}
