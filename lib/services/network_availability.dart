// lib/services/network_availability.dart
// DIAGNOSTICS ONLY — this is NOT the app's online/offline signal.
//
// The app's status comes from Supabase reachability alone; see
// `supabase_reachability.dart`. Everything here answers a narrower question
// ("is the platform reporting a transport / is some URL reachable?") and is
// used for two things only: log context, and skipping a request that is
// certain to fail. Nothing here may declare the app online or offline.
//
// connectivity_plus is a CHANGE HINT only, and an unreliable one:
//   - On Windows its NetworkManager plugin reports [ConnectivityResult.none]
//     and throws from the event stream (E_INVALIDARG) on a healthy network.
//   - On mobile a "none" result can also be wrong (captive portal, VPN
//     handover, dual-SIM switch) and "wifi" says nothing about upstream.
//   - On web it is just navigator.onLine, which reports link state only.
//
// So a "no transport" hint must always be confirmed by a real HTTP probe
// before a request is skipped. A reported transport is accepted immediately
// (no request) — that fast path is the only thing the plugin is still good for.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matchme/services/runtime_supabase_config.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 204 endpoint used when no Supabase endpoint is available yet (early
/// bootstrap) or when the backend probes are not usable for the caller.
const String _connectivityProbeUrl =
    'https://clients3.google.com/generate_204';

/// Resolved transport signal.
class NetworkTransportSignal {
  const NetworkTransportSignal({
    required this.hasTransport,
    this.internetReachable,
  });

  /// True when the network is usable — either the platform reported a
  /// transport, or an HTTP probe succeeded after a "no transport" hint.
  final bool hasTransport;

  /// Reachability from a probe that already ran, or null when the platform
  /// hint was enough. Lets callers skip a second identical request.
  final bool? internetReachable;
}

/// The "hint contradicted by a probe" notice is informational and, where the
/// plugin is permanently wrong, would otherwise repeat on every probe.
bool _notifiedContradictingHint = false;

/// Probes the real internet. Tries the Supabase endpoints first (fast, no
/// third party, works cross-origin on web), then the generate_204 endpoint as
/// a backend-independent fallback. Auth/RLS rejections count as reachable:
/// the server answered, so the network is up.
///
/// Diagnostic: use this to explain *why* Supabase is unreachable, never to
/// decide whether the app is online. A device with a working internet and a
/// dead Supabase project is offline as far as this app is concerned.
Future<bool> isInternetReachable({
  Duration timeout = const Duration(seconds: 5),
}) async {
  final baseUrl = (runtimeSupabaseUrl ?? '').trim().replaceFirst(
    RegExp(r'/$'),
    '',
  );

  if (baseUrl.isNotEmpty) {
    try {
      final uri = Uri.parse('$baseUrl/auth/v1/health');
      final headers = <String, String>{'cache-control': 'no-cache'};
      final anonKey = runtimeSupabaseAnonKey;
      if (anonKey != null && anonKey.isNotEmpty) {
        headers['apikey'] = anonKey;
      }
      final response = await http.get(uri, headers: headers).timeout(timeout);
      if (response.statusCode >= 200 && response.statusCode < 400) return true;
    } catch (_) {
      // Fall through to the RPC probe.
    }
  }

  try {
    await Supabase.instance.client.rpc('health_check').timeout(timeout);
    return true;
  } catch (e) {
    if (isAuthRateLimitFailure(e)) return true;
    // Supabase may not be initialized yet (early bootstrap) — fall through
    // instead of reporting a false offline.
  }

  // generate_204 is blocked by CORS on web, so it is the last resort only.
  if (kIsWeb) return false;
  try {
    final response = await http
        .get(Uri.parse(_connectivityProbeUrl))
        .timeout(timeout);
    // Any HTTP answer means the network is up (captive portals included).
    return response.statusCode > 0;
  } catch (_) {
    return false;
  }
}

/// Resolves the platform transport hint into a real answer, confirming a
/// "no transport" hint with an HTTP probe.
///
/// Diagnostic/pre-flight only. [transportResults] reuses a result that the
/// caller already has (e.g. from the connectivity change event) instead of
/// querying the plugin again.
Future<NetworkTransportSignal> resolveNetworkTransport({
  Duration timeout = const Duration(seconds: 5),
  List<ConnectivityResult>? transportResults,
}) async {
  List<ConnectivityResult> results;
  if (transportResults != null) {
    results = transportResults;
  } else {
    try {
      results = await Connectivity().checkConnectivity();
    } catch (e) {
      debugPrint('🌐 [NETWORK] connectivity_plus check failed: $e');
      results = const [];
    }
  }

  // Reported transport: accept it, no request needed.
  if (results.isNotEmpty && !results.contains(ConnectivityResult.none)) {
    return const NetworkTransportSignal(hasTransport: true);
  }

  // Reported "no transport" (or an unusable result): only believe it when a
  // real probe fails too.
  final reachable = await isInternetReachable(timeout: timeout);
  if (reachable) {
    if (!_notifiedContradictingHint) {
      _notifiedContradictingHint = true;
      debugPrint(
        '🌐 [NETWORK] connectivity_plus reported no transport but the HTTP probe '
        'succeeded - treating the hint as a change hint only',
      );
      // Duplicated with the BOOTSTRAP prefix so it survives main.dart's
      // debugPrint filter and stays visible in the run log.
      debugPrint(
        '⏱️ [BOOTSTRAP] connectivity_plus "no transport" hint overridden by '
        'successful HTTP probe',
      );
    }
    return NetworkTransportSignal(hasTransport: true, internetReachable: true);
  }
  return NetworkTransportSignal(hasTransport: false, internetReachable: false);
}

/// Convenience wrapper: is the network usable right now?
///
/// Superseded by [probeSupabaseReachability] for anything the user can see:
/// "the network is up" is not the same as "the app works". Kept for the few
/// callers that only need to avoid obviously doomed third-party requests.
Future<bool> isNetworkAvailable({
  Duration timeout = const Duration(seconds: 5),
}) async {
  final signal = await resolveNetworkTransport(timeout: timeout);
  return signal.hasTransport;
}

/// True on Android/iOS.
bool get isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Scales a network timeout for the platform.
///
/// Cold-start DNS + TLS + PostgREST on a mobile connection routinely takes
/// several seconds, so a budget that is generous on desktop produces false
/// health-check failures and wasted retries on a phone. Capped so a genuinely
/// dead network is still detected promptly.
Duration platformProbeTimeout(Duration desktopTimeout) {
  if (!isMobilePlatform) return desktopTimeout;
  final scaled = desktopTimeout * 2;
  const cap = Duration(seconds: 12);
  return scaled > cap ? cap : scaled;
}
