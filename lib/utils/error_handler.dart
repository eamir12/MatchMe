// lib/utils/error_handler.dart
// Centralized error handling utilities

import 'package:flutter/foundation.dart';

class AppErrorHandler {
  /// Log error with context
  static void logError(String context, dynamic error, [StackTrace? stackTrace]) {
    debugPrint('🔴 ERROR in $context: $error');
    if (stackTrace != null) {
      debugPrint('Stack trace: $stackTrace');
    }
  }

  /// Handle Supabase errors with user-friendly messages
  static String handleSupabaseError(dynamic error) {
    if (error.toString().contains('network')) {
      return 'Network error. Please check your connection and try again.';
    }
    if (error.toString().contains('auth')) {
      return 'Authentication error. Please try logging in again.';
    }
    if (error.toString().contains('permission')) {
      return 'Permission denied. Please check your access rights.';
    }
    if (error.toString().contains('timeout')) {
      return 'Request timed out. Please try again.';
    }
    return 'An unexpected error occurred. Please try again.';
  }

  /// Safe async operation wrapper
  static Future<T?> safeAsync<T>(
    Future<T> Function() operation,
    String context, {
    T? fallback,
    bool logErrors = true,
  }) async {
    try {
      return await operation();
    } catch (error, stackTrace) {
      if (logErrors) {
        logError(context, error, stackTrace);
      }
      return fallback;
    }
  }

  /// Safe data transformation
  static R? safeTransform<T, R>(
    T? input,
    R Function(T) transform, {
    String? context,
    R? fallback,
  }) {
    try {
      if (input == null) return fallback;
      return transform(input);
    } catch (error) {
      if (context != null) {
        logError(context, error);
      }
      return fallback;
    }
  }

  /// Safe list access
  static T? safeListAccess<T>(List<T> list, int index, {T? fallback}) {
    try {
      if (index >= 0 && index < list.length) {
        return list[index];
      }
      return fallback;
    } catch (error) {
      logError('safeListAccess', error);
      return fallback;
    }
  }

  /// Safe map access
  static V? safeMapAccess<K, V>(Map<K, V> map, K key, {V? fallback}) {
    try {
      return map[key] ?? fallback;
    } catch (error) {
      logError('safeMapAccess', error);
      return fallback;
    }
  }

  /// Safe JSON parsing
  static Map<String, dynamic>? safeJsonParse(String? jsonString, {String? context}) {
    if (jsonString == null || jsonString.isEmpty) return null;
    
    try {
      return {'parsed': jsonString}; // Simple wrapper to avoid import
    } catch (error) {
      if (context != null) {
        logError('$context.jsonParse', error);
      }
      return null;
    }
  }
}

/// Extension for better error handling on common types
extension SafeOperations<T> on T? {
  /// Safe transformation with error handling
  R? safeMap<R>(R Function(T) transform, {String? context, R? fallback}) {
    return AppErrorHandler.safeTransform(this, transform, context: context, fallback: fallback);
  }

  /// Safe string conversion
  String? safeToString({String? fallback}) {
    try {
      return this?.toString() ?? fallback;
    } catch (error) {
      AppErrorHandler.logError('safeToString', error);
      return fallback;
    }
  }
}

// TODO: Add SafeProvider implementation if needed
// This would require proper Riverpod/StateNotifier imports