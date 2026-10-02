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

import 'package:flutter/foundation.dart';
import 'package:matchme/services/network_availability.dart';
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
  log?.call('Supabase probe attempt 1 (budget ${budget.inSeconds}s)');
  final first = await _attemptSupabaseProbe(probe, budget, 1, log: log);
  if (first != null) return first;

  if (!confirm) {
    return SupabaseReachResult.unreachable(
      failureKind: SupabaseFailureKind.noResponse,
      detail: 'no response within ${budget.inSeconds}s',
    );
  }

  if (confirmDelay > Duration.zero) {
    await Future<void>.delayed(confirmDelay);
  }
  log?.call('Supabase probe attempt 2 (budget ${confirmBudget.inSeconds}s)');
  final second = await _attemptSupabaseProbe(probe, confirmBudget, 2, log: log);
  if (second != null) return second;

  return SupabaseReachResult.unreachable(
    failureKind: SupabaseFailureKind.noResponse,
    detail: 'no response within ${confirmBudget.inSeconds}s',
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

SupabaseClient? _supabaseClientOrNull() {
  try {
    return Supabase.instance.client;
  } catch (_) {
    // Not initialized yet (early bootstrap) — indistinguishable from "no
    // response" for our purposes, and a confirming attempt is still allowed.
    return null;
  }
}

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
  final client = _supabaseClientOrNull();
  if (client == null) {
    log?.call('Supabase is not initialized yet');
    return const SupabaseReachResult.unreachable(
      failureKind: SupabaseFailureKind.noResponse,
      detail: 'Supabase not initialized',
    );
  }

  return evaluateSupabaseProbe(
    (budget) => _runHealthCheck(client, budget),
    budget: timeout ?? platformProbeTimeout(kSupabaseProbeTimeout),
    confirmBudget: platformProbeTimeout(kSupabaseConfirmTimeout),
    confirm: confirm,
    log: log,
  );
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
