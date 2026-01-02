// lib/providers/connectivity_provider.dart
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// This provider creates a stream that broadcasts the network status.
/// It correctly handles the web platform's limitations by combining connectivity_plus
/// with periodic actual Supabase connectivity checks.
final connectivityProvider = StreamProvider<bool>((ref) async* {
  final controller = StreamController<bool>();
  bool disposed = false;

  void safeAdd(bool value) {
    if (disposed) return;
    if (controller.isClosed) return;
    try {
      controller.add(value);
    } catch (_) {
      // ignore add-after-close races
    }
  }

  // Function to check actual internet connectivity by testing Supabase connectivity
  Future<bool> checkInternetConnectivity() async {
    try {
      // Try to reach Supabase by calling a lightweight RPC `health_check()`
      // This avoids anonymous clients needing SELECT on the `users` table.
      final dynamic resp = await Supabase.instance.client.rpc('health_check').maybeSingle().timeout(const Duration(seconds: 5));

      // If response is null, consider it a failure
      if (resp == null) return false;

      // Convert response to a Map<String, dynamic> safely to normalize PostgrestMap types
      Map<String, dynamic>? m;
      if (resp is Map) {
        try {
          m = Map<String, dynamic>.from(resp);
        } catch (_) {
          m = null;
        }
      }

      if (m != null) {
        final dynamic okVal = m['ok'];
        if (okVal is bool) return okVal;
        if (okVal is String) return okVal.toLowerCase() == 'true';
        return false;
      }

      // Legacy fallback: some DBs returned boolean directly
      if (resp is bool) return resp;

      return false;
    } catch (e) {
      return false;
    }
  }

  // Get the initial status
  var initialResults = await Connectivity().checkConnectivity();
  bool isOnline = !initialResults.contains(ConnectivityResult.none);
  // Check actual connectivity on all platforms
  isOnline = isOnline && await checkInternetConnectivity();
  safeAdd(isOnline);

  // Listen for changes from connectivity_plus
  final connectivitySubscription = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) async {
    bool newOnline = !results.contains(ConnectivityResult.none);
    // Check actual connectivity on all platforms
    if (newOnline) {
      newOnline = await checkInternetConnectivity();
    }
    safeAdd(newOnline);
  });

  // Periodic check every 3 seconds to catch delayed disconnections
  final periodicTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
    final currentConnectivity = await Connectivity().checkConnectivity();
    final connectivityOnline = !currentConnectivity.contains(ConnectivityResult.none);
    final actualOnline = await checkInternetConnectivity();
    final newOnline = connectivityOnline && actualOnline;
    safeAdd(newOnline);
  });

  // Yield from the controller
  yield* controller.stream;

  // Cleanup
  ref.onDispose(() {
    disposed = true;
    connectivitySubscription.cancel();
    periodicTimer.cancel();
    if (!controller.isClosed) {
      controller.close();
    }
  });
});
