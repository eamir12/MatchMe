// lib/services/supabase_reachability.dart
// Single source of truth for "can this app talk to Supabase right now?".
//
// Supabase IS the app: profiles, matches, chats, presence, translations and
// config all live there. A device with working internet that cannot complete a
// round trip with Supabase has nothing to show, so the ONLY online/offline
// signal is Supabase reachability. Connectivity transport hints and generic
// internet probes are diagnostics and probe-scheduling hints — they may make us
// probe sooner, they may never declare the app online or offline.
//
// Probe decision table (`health_check` RPC, one request):
//
//   | Outcome                                  | Verdict   | Why                        |
//   |------------------------------------------|-----------|----------------------------|
//   | 2xx with {"ok": true}                    | reachable | server answered and works  |
//   | 2xx with {"ok": false}                   | unreachable | answered, but unhealthy  |
//   | auth / RLS / 429 rejection               | reachable | server answered            |
//   | 5xx / 504 (a response was received)      | unreachable | gateway answered, DB not  |
//   | nothing inside the budget                | confirm once, then unreachable |
//
// The budget is deliberately larger than Supabase's own gateway timeout
// (~5.3s measured for a stalled database) so a database stall is observed as an
// HTTP response instead of an ambiguous client-side timeout. That is what makes
// "the server answered but cannot serve us" distinguishable from "no server".

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matchme/services/network_availability.dart';
import 'package:matchme/services/runtime_supabase_config.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Per-attempt probe budget (desktop) for the background monitor and for
/// runtime transitions. Deliberately larger than Supabase's own gateway
/// timeout (~5.3s measured for a stalled database), so a database stall is
/// observed as an HTTP response instead of an ambiguous client-side timeout.
const Duration kSupabaseProbeTimeout = Duration(seconds: 8);

/// Budget for the optional confirming attempt (desktop).
const Duration kSupabaseConfirmTimeout = Duration(seconds: 12);

/// Budget for the cold-start gate, which runs while the splash screen is up.
///
/// The monitor can afford a generous budget because nothing is waiting on it,
/// but the splash is: the app must not sit on a flashing logo for the ~5.3s
/// Kong needs to give up on a stalled database, let alone the ~11s the SDK
/// spent on that call. A healthy `health_check` (SELECT 1) answers in a few
/// hundred milliseconds even on a cold mobile connection, so this budget is
/// generous for a live backend and only bites when something is actually
/// wrong. Mobile is scaled by [platformProbeTimeout] to 3s.
///
/// A false negative here is safe and self-correcting: the app lands in cached
/// mode, and the monitor — which keeps the full budget — confirms within
/// seconds and restores the online state.
const Duration kSupabaseStartupProbeTimeout = Duration(milliseconds: 1500);

/// Mobile startup budget. A cold first HTTPS request to a new host costs DNS +
/// TCP + TLS before the query even runs (routinely 1-2s on mobile data), and
/// that cost is paid on the very request the splash is waiting for. 4s leaves
/// room for a healthy backend on a mediocre connection while still staying far
/// below the ~5.3s Kong needs to give up on a stalled database.
const Duration kSupabaseStartupProbeTimeoutMobile = Duration(seconds: 4);

/// Budget for the cold-start gate, already scaled for the platform.
Duration startupSupabaseProbeBudget() {
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    return kSupabaseStartupProbeTimeoutMobile;
  }
  return kSupabaseStartupProbeTimeout;
}

enum SupabaseReachStatus {
  /// Supabase answered and can serve requests.
  reachable,

  /// Supabase could not be reached, or answered but could not serve the
  /// request. This is the app's only "offline" state.
  unreachable,
}

/// Why a probe came back unreachable. Diagnostics only — both kinds mean
/// "offline", they just describe it differently in the log.
enum SupabaseFailureKind {
  /// Nothing came back inside the budget (DNS, socket, TLS, stall).
  noResponse,

  /// Supabase answered with an error (5xx / 504 and friends).
  serverError,
}

class SupabaseReachResult {
  const SupabaseReachResult({
    required this.status,
    this.failureKind,
    this.detail,
    this.attempts = 1,
  });

  const SupabaseReachResult.reachable({int attempts = 1})
    : this(status: SupabaseReachStatus.reachable, attempts: attempts);

  const SupabaseReachResult.unreachable({
    required SupabaseFailureKind failureKind,
    String? detail,
    int attempts = 1,
  }) : this(
         status: SupabaseReachStatus.unreachable,
         failureKind: failureKind,
         detail: detail,
         attempts: attempts,
       );

  final SupabaseReachStatus status;

  /// Set when [status] is [SupabaseReachStatus.unreachable].
  final SupabaseFailureKind? failureKind;

  /// Raw error text, for the log only.
  final String? detail;

  /// How many RPC attempts were made before this verdict.
  final int attempts;

  bool get isReachable => status == SupabaseReachStatus.reachable;

  bool get isUnreachable => status == SupabaseReachStatus.unreachable;

  @override
  String toString() {
    if (isReachable) return 'reachable(attempts=$attempts)';
    return 'unreachable(kind=${failureKind?.name}, attempts=$attempts, $detail)';
  }
}

/// Markers of "the request never got an answer".
///
/// Matched on the error text rather than on `SocketException` /
/// `HandshakeException` so the check compiles for web, where those dart:io
/// types do not exist. Deliberately narrow: a PostgREST error for a stalled
/// database reads `PostgrestException(message: Gateway Timeout, ...)` and must
/// NOT match, because receiving it proves the server is reachable.
const List<String> _noResponseMarkers = <String>[
  'clientexception',
  'sockexception',
  'failed host lookup',
  'no address associated',
  'connection refused',
  'connection reset',
  'connection closed',
  'connectionterminated',
  'handshakeexception',
  'network is unreachable',
  'networkisunreachable',
  'os error',
  // PostgrestBuilder.abortSignal(): we cancelled the request ourselves when our
  // own budget expired, so nothing can come back.
  'requestaborted',
];

/// True when the failure means nothing came back at all.
bool isSupabaseNoResponseFailure(Object error) {
  if (error is TimeoutException) return true;
  final text = error.toString().toLowerCase();
  return _noResponseMarkers.any(text.contains);
}

/// True when the `health_check` payload reports the backend as unhealthy.
///
/// `health_check()` catches its own internal failures and answers
/// `{"ok": false, "error": ...}` instead of raising, so a *completed* call is
/// not automatically good news: Supabase answered but cannot do the work.
bool reportsUnhealthyBackend(Object? value) {
  if (value is! Map) return false;
  final ok = value['ok'];
  if (ok is bool) return !ok;
  if (ok is String) return ok.toLowerCase() == 'false';
  return false;
}

/// Decision engine over an arbitrary [probe], so the verdict logic is testable
/// without a live backend.
///
/// Runs one attempt. When nothing answered and [confirm] is set, runs a second
/// attempt with the larger [confirmBudget] — a confirmation is only ever spent
/// on an ambiguous "no response", never on a server that already answered with
/// an error.
///
/// [log] receives human-readable progress lines; callers pass their own prefix.
Future<SupabaseReachResult> evaluateSupabaseProbe(
  Future<Object?> Function(Duration budget) probe, {
  Duration budget = kSupabaseProbeTimeout,
  Duration confirmBudget = kSupabaseConfirmTimeout,
  bool confirm = false,
  Duration confirmDelay = const Duration(milliseconds: 400),
  void Function(String message)? log,
}) async {
  log?.call('Supabase probe attempt 1 (budget ${budget.inMilliseconds}ms)');
  final first = await _attemptSupabaseProbe(probe, budget, 1, log: log);
  if (first != null) return first;

  if (!confirm) {
    return SupabaseReachResult.unreachable(
      failureKind: SupabaseFailureKind.noResponse,
      detail: 'no response within ${budget.inMilliseconds}ms',
    );
  }

  if (confirmDelay > Duration.zero) {
    await Future<void>.delayed(confirmDelay);
  }
  log?.call(
    'Supabase probe attempt 2 (budget ${confirmBudget.inMilliseconds}ms)',
  );
  final second = await _attemptSupabaseProbe(probe, confirmBudget, 2, log: log);
  if (second != null) return second;

  return SupabaseReachResult.unreachable(
    failureKind: SupabaseFailureKind.noResponse,
    detail: 'no response within ${confirmBudget.inMilliseconds}ms',
    attempts: 2,
  );
}

/// One attempt. Returns null when the failure is a "no response" that a
/// confirming attempt could still disprove.
Future<SupabaseReachResult?> _attemptSupabaseProbe(
  Future<Object?> Function(Duration budget) probe,
  Duration budget,
  int attempt, {
  void Function(String message)? log,
}) async {
  final stopwatch = Stopwatch()..start();
  try {
    final value = await probe(budget);
    stopwatch.stop();
    if (reportsUnhealthyBackend(value)) {
      log?.call(
        'Supabase answered in ${stopwatch.elapsedMilliseconds}ms but reported itself unhealthy: $value',
      );
      return SupabaseReachResult.unreachable(
        failureKind: SupabaseFailureKind.serverError,
        detail: 'health_check reported ok=false ($value)',
        attempts: attempt,
      );
    }
    log?.call(
      'Supabase reachable on attempt $attempt in ${stopwatch.elapsedMilliseconds}ms',
    );
    return SupabaseReachResult.reachable(attempts: attempt);
  } on TimeoutException catch (e) {
    stopwatch.stop();
    log?.call(
      'Supabase probe attempt $attempt gave up after ${stopwatch.elapsedMilliseconds}ms (budget ${budget.inMilliseconds}ms): $e',
    );
    return null;
  } catch (e) {
    stopwatch.stop();
    // An auth/RLS/rate-limit rejection still proves the server is there, so it
    // must not be read as an outage (see isAuthRateLimitFailure).
    if (isAuthRateLimitFailure(e)) {
      log?.call(
        'Supabase reachable on attempt $attempt in ${stopwatch.elapsedMilliseconds}ms (auth rejection: $e)',
      );
      return SupabaseReachResult.reachable(attempts: attempt);
    }
    if (isSupabaseNoResponseFailure(e)) {
      log?.call(
        'Supabase probe attempt $attempt got no response in ${stopwatch.elapsedMilliseconds}ms: $e',
      );
      // A DNS/route failure is a definitive answer, not an ambiguous stall:
      // the device has no way to reach the host right now, so a confirming
      // attempt only doubles the offline-detection latency (8s + 12s on
      // mobile when the resolver hangs). Timeouts and resets stay ambiguous
      // and still get the confirmation attempt.
      if (_isDefinitiveNoResponseFailure(e)) {
        return SupabaseReachResult.unreachable(
          failureKind: SupabaseFailureKind.noResponse,
          detail: '$e',
          attempts: attempt,
        );
      }
      return null;
    }
    log?.call(
      'Supabase probe attempt $attempt got an error response in ${stopwatch.elapsedMilliseconds}ms: $e',
    );
    return SupabaseReachResult.unreachable(
      failureKind: SupabaseFailureKind.serverError,
      detail: '$e',
      attempts: attempt,
    );
  }
}

/// True when the error proves the host cannot be reached at all (bad DNS or
/// no route), instead of a request that merely failed to answer in time.
bool _isDefinitiveNoResponseFailure(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('failed host lookup') ||
      text.contains('no address associated with hostname') ||
      text.contains('nodename nor servname provided') ||
      text.contains('network is unreachable') ||
      text.contains('networkisunreachable');
}

SupabaseClient? _supabaseClientOrNull() {
  try {
    return Supabase.instance.client;
  } catch (_) {
    // Not initialized yet (early bootstrap) — indistinguishable from "no
    // response" for our purposes, and a confirming attempt is still allowed.
    return null;
  }
}

/// Coalescing for the *default* runtime probe (null timeout, no confirm).
///
/// At startup several subsystems (connectivity monitor, ad providers, chat)
/// fire the default probe within the same instant. Running them independently
/// meant 3-5 concurrent `health_check` round trips against an already-stressed
/// (or dead) backend, each holding its own socket. We share one in-flight
/// future so they all observe the same verdict from a single round trip.
///
/// Callers that pass an explicit [timeout] or [confirm] (the bootstrap gates,
/// the connectivity monitor's own budgeted probes) are NOT coalesced — their
/// budgets and semantics differ, and sharing would corrupt the verdict.
Future<SupabaseReachResult>? _inFlightDefaultProbe;

/// Probes Supabase with the `health_check` RPC.
///
/// [timeout] replaces the per-attempt budget **verbatim** — the caller decides,
/// so an explicit value is never re-scaled (use [startupSupabaseProbeBudget] to
/// get a platform-appropriate value). Leaving it null applies
/// [kSupabaseProbeTimeout] with [platformProbeTimeout] scaling, which is what
/// the background monitor and the runtime paths want.
///
/// When the budget expires the in-flight request is cancelled through PostgREST's
/// `abortSignal`, instead of being left dangling until the gateway finally
/// gives up (~5.3s measured) — that leaked socket used to outlive the decision
/// it was blocking.
///
/// [confirm] adds the second, larger-budget attempt. Use it when a wrong
/// offline verdict is expensive. Leave it off for the one-shot gates.
Future<SupabaseReachResult> probeSupabaseReachability({
  Duration? timeout,
  bool confirm = false,
  void Function(String message)? log,
}) async {
  // Probe with the anon key instead of the signed-in session. Any RPC through
  // the authenticated client can silently refresh an expired access token;
  // when the network is down that refresh retries for ~30s and, once DNS
  // returns, spends a refresh token that another refresher may already have
  // rotated — surfacing `refresh_token_already_used` and tearing down the
  // session during what was only supposed to be a connectivity check.
  // `health_check` is granted to `anon`, so a raw request proves the same
  // thing without touching auth state (and fails immediately on dead DNS
  // instead of hanging inside gotrue's retry loop).
  final url = (runtimeSupabaseUrl ?? '').trim();
  final anonKey = (runtimeSupabaseAnonKey ?? '').trim();
  final useAnonProbe = url.isNotEmpty && anonKey.isNotEmpty;

  final client = _supabaseClientOrNull();
  if (!useAnonProbe && client == null) {
    log?.call('Supabase is not initialized yet');
    return const SupabaseReachResult.unreachable(
      failureKind: SupabaseFailureKind.noResponse,
      detail: 'Supabase not initialized',
    );
  }

  final isDefaultRuntimeProbe = timeout == null && !confirm;
  if (isDefaultRuntimeProbe) {
    final inFlight = _inFlightDefaultProbe;
    if (inFlight != null) {
      log?.call('Joining in-flight default Supabase probe');
      return inFlight;
    }
  }

  final future = evaluateSupabaseProbe(
    (budget) => useAnonProbe
        ? _runAnonHealthCheck(url: url, anonKey: anonKey, budget: budget)
        : _runHealthCheck(client!, budget),
    budget: timeout ?? platformProbeTimeout(kSupabaseProbeTimeout),
    confirmBudget: platformProbeTimeout(kSupabaseConfirmTimeout),
    confirm: confirm,
    log: log,
  );

  if (isDefaultRuntimeProbe) {
    _inFlightDefaultProbe = future;
    // Clear the shared slot once settled so later probes run fresh.
    unawaited(
      future.whenComplete(() {
        if (identical(_inFlightDefaultProbe, future)) {
          _inFlightDefaultProbe = null;
        }
      }),
    );
  }

  return future;
}

/// One `health_check` round trip that never touches the signed-in session.
///
/// See [probeSupabaseReachability] for why this exists. Uses the anon key
/// directly so no access-token refresh (and no rotating refresh-token use)
/// can be triggered by a connectivity probe.
Future<Object?> _runAnonHealthCheck({
  required String url,
  required String anonKey,
  required Duration budget,
}) async {
  final base = url.replaceFirst(RegExp(r'/+$'), '');
  final client = http.Client();
  try {
    final response = await client
        .post(
          Uri.parse('$base/rest/v1/rpc/health_check'),
          headers: <String, String>{
            'apikey': anonKey,
            'Authorization': 'Bearer $anonKey',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'cache-control': 'no-cache',
          },
          body: '{}',
        )
        .timeout(budget);
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      final body = response.body.trim();
      if (body.isEmpty) return null;
      try {
        return jsonDecode(body);
      } catch (_) {
        // A 2xx is proof the backend answered even if the body is not JSON.
        return null;
      }
    }
    // Auth/RLS/rate-limit rejections still prove the server is there.
    if (status == 401 || status == 403 || status == 429) {
      throw _ProbeHttpRejection(status);
    }
    throw PostgrestException(
      message: 'health_check answered HTTP $status',
      code: 'PGRST$status',
    );
  } finally {
    // Also aborts an in-flight request when [budget] won, so a stalled
    // gateway does not leave a socket behind.
    client.close();
  }
}

/// An auth/RLS/rate-limit answer from the raw probe. Treated as "reachable"
/// by [evaluateSupabaseProbe]; the message shape matches
/// `isAuthRateLimitFailure`.
class _ProbeHttpRejection implements Exception {
  const _ProbeHttpRejection(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'health_check auth rejection (statusCode: $statusCode)';
}

/// One `health_check` round trip that is actually cancelled when [budget] wins.
Future<Object?> _runHealthCheck(SupabaseClient client, Duration budget) async {
  final cancel = Completer<void>();
  final request = client.rpc('health_check').abortSignal(cancel.future);
  try {
    return await request.timeout(budget);
  } on TimeoutException {
    if (!cancel.isCompleted) cancel.complete();
    rethrow;
  }
}
