// test/services/supabase_reachability_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/supabase_reachability.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('isSupabaseNoResponseFailure', () {
    test('client/socket failures mean nothing came back', () {
      expect(isSupabaseNoResponseFailure(TimeoutException('probe')), isTrue);
      expect(
        isSupabaseNoResponseFailure(
          const HttpExceptionStub('ClientException: Connection closed'),
        ),
        isTrue,
      );
      expect(
        isSupabaseNoResponseFailure(
          const HttpExceptionStub('SocketException: Failed host lookup'),
        ),
        isTrue,
      );
    });

    test('a request we cancelled ourselves is a no-response failure', () {
      // postgrest's abortSignal: our own budget expired, so nothing can come
      // back and the result must not be read as an answered request.
      expect(
        isSupabaseNoResponseFailure(
          const HttpExceptionStub('RequestAbortedException: request aborted'),
        ),
        isTrue,
      );
    });


    test('an error response from the gateway is NOT a no-response failure', () {
      // This is the Supabase-database-down case: Kong answered with 504 after
      // ~5.3s. Receiving it proves the server is reachable, so the probe must
      // not spend a confirming attempt on it.
      final error = PostgrestException(
        message: 'Gateway Timeout',
        code: 'PGRST000',
      );
      expect(isSupabaseNoResponseFailure(error), isFalse);
      expect(
        PostgrestException(message: 'Gateway Timeout').toString(),
        isNot(contains('sockexception')),
      );
    });

    test('the real 504 from supabase is an answered request, not a dead one',
        () {
      // Observed on device: the supabase client surfaces a stalled-database 504
      // as AuthRetryableFetchException, not PostgrestException. It must still
      // read as "the gateway answered" so the verdict stays serverError.
      final error = AuthRetryableFetchException(
        message: '{"message":"Gateway Timeout"}',
        statusCode: '504',
      );
      expect(isSupabaseNoResponseFailure(error), isFalse);
    });
  });


  group('startup probe budget', () {
    test('is far below the gateway timeout and above a healthy round trip', () {
      // Measured against the live project: a stalled database answers with a
      // 504 after ~5.3s, a healthy health_check in a few hundred ms. The
      // cold-start budget has to sit between the two, or the splash either
      // waits ~5s or starts healthy apps in cached mode.
      expect(
        kSupabaseStartupProbeTimeout,
        lessThan(const Duration(milliseconds: 2000)),
      );
      expect(
        kSupabaseStartupProbeTimeoutMobile,
        lessThan(const Duration(milliseconds: 5000)),
      );
      expect(
        kSupabaseStartupProbeTimeoutMobile,
        greaterThan(kSupabaseStartupProbeTimeout),
        reason: 'a cold mobile TLS handshake needs more room than desktop',
      );
    });

    test('startupSupabaseProbeBudget returns a bounded value on every platform',
        () {
      final budget = startupSupabaseProbeBudget();
      expect(budget, lessThan(const Duration(seconds: 5)));
      expect(budget, greaterThanOrEqualTo(const Duration(milliseconds: 1000)));
    });
  });

  group('evaluateSupabaseProbe', () {

    test('a successful round trip is reachable on the first attempt', () async {
      var calls = 0;
      final result = await evaluateSupabaseProbe((_) async {
        calls += 1;
        return <String, dynamic>{'ok': true};
      }, confirm: true);

      expect(result.isReachable, isTrue);
      expect(result.attempts, 1);
      expect(calls, 1);
    });

    test('a 200 response reporting ok=false is offline', () async {
      var calls = 0;
      final result = await evaluateSupabaseProbe((_) async {
        calls += 1;
        return <String, dynamic>{'ok': false, 'error': 'relation missing'};
      }, confirm: true);

      expect(result.isUnreachable, isTrue);
      expect(result.failureKind, SupabaseFailureKind.serverError);
      expect(calls, 1);
    });

    test('reportsUnhealthyBackend reads the health_check payload', () {
      expect(reportsUnhealthyBackend(<String, dynamic>{'ok': true}), isFalse);
      expect(reportsUnhealthyBackend(<String, dynamic>{'ok': false}), isTrue);
      expect(reportsUnhealthyBackend(<String, dynamic>{'ok': 'false'}), isTrue);
      expect(reportsUnhealthyBackend(<String, dynamic>{'ok': 'true'}), isFalse);
      expect(reportsUnhealthyBackend(null), isFalse);
      expect(reportsUnhealthyBackend(true), isFalse);
    });

    test('an auth/RLS rejection still counts as reachable', () async {
      final result = await evaluateSupabaseProbe((_) async {
        throw PostgrestException(
          message: 'permission denied for function health_check',
          code: '42501',
        );
      }, confirm: true);

      expect(result.isReachable, isTrue);
    });

    test('a 5xx/504 response is offline without a confirming attempt', () async {
      var calls = 0;
      final result = await evaluateSupabaseProbe((_) async {
        calls += 1;
        throw PostgrestException(
          message: 'Gateway Timeout',
          code: 'PGRST000',
        );
      }, confirm: true);

      expect(result.isUnreachable, isTrue);
      expect(result.failureKind, SupabaseFailureKind.serverError);
      expect(calls, 1, reason: 'the server already answered; do not re-ask');
    });

    test('the device-observed 504 shape is offline after a single attempt',
        () async {
      var calls = 0;
      final result = await evaluateSupabaseProbe(
        (_) async {
          calls += 1;
          throw AuthRetryableFetchException(
            message: '{"message":"Gateway Timeout"}',
            statusCode: '504',
          );
        },
        confirm: true,
      );

      expect(result.isUnreachable, isTrue);
      expect(result.failureKind, SupabaseFailureKind.serverError);
      expect(calls, 1);
    });


    test('no response is offline after a single attempt when not confirming',
        () async {
      var calls = 0;
      final result = await evaluateSupabaseProbe(
        (_) async {
          calls += 1;
          throw TimeoutException('probe', const Duration(seconds: 8));
        },
        confirm: false,
      );

      expect(result.isUnreachable, isTrue);
      expect(result.failureKind, SupabaseFailureKind.noResponse);
      expect(calls, 1);
    });

    test('no response is revived by a successful confirming attempt', () async {
      var calls = 0;
      final result = await evaluateSupabaseProbe(
        (_) async {
          calls += 1;
          if (calls == 1) {
            throw TimeoutException('probe', const Duration(seconds: 8));
          }
          return <String, dynamic>{'ok': true};
        },

        confirm: true,
        confirmDelay: Duration.zero,
      );

      expect(result.isReachable, isTrue);
      expect(result.attempts, 2);
      expect(calls, 2);
    });

    test('no response on both attempts is offline', () async {
      var calls = 0;
      final result = await evaluateSupabaseProbe(
        (_) async {
          calls += 1;
          throw const HttpExceptionStub('ClientException: Connection refused');
        },
        confirm: true,
        confirmDelay: Duration.zero,
      );

      expect(result.isUnreachable, isTrue);
      expect(result.failureKind, SupabaseFailureKind.noResponse);
      expect(result.attempts, 2);
      expect(calls, 2);
    });

    test('the confirming attempt gets the larger budget', () async {
      final budgets = <Duration>[];
      await evaluateSupabaseProbe(
        (budget) async {
          budgets.add(budget);
          throw TimeoutException('probe', budget);
        },
        budget: const Duration(seconds: 8),
        confirmBudget: const Duration(seconds: 12),
        confirm: true,
        confirmDelay: Duration.zero,
      );

      expect(budgets, [
        const Duration(seconds: 8),
        const Duration(seconds: 12),
      ]);
    });
  });
}

/// Minimal stand-in for the `http` package's ClientException, which is what
/// `package:http` throws when a request never reaches a server.
class HttpExceptionStub implements Exception {
  const HttpExceptionStub(this.message);
  final String message;

  @override
  String toString() => message;
}
