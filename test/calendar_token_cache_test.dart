// test/calendar_token_cache_test.dart
//
// Removing a connected calendar account must actually discard the provider
// credentials, not just the list entry. `removeAccount` drops the
// ConnectedOnlineAccount (which carries its own accessToken) and then calls
// clearGoogleImportTokenCache / clearOutlookImportTokenCache once the last
// account of that provider is gone.
//
// Those clear helpers route through cache*ImportToken with an empty token, which
// nulls the in-memory statics and deletes the secure-storage keys. This test
// pins that guarantee, because a silent no-op here would leave a live calendar
// access token on the device after the user disconnected the account.

import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/calendar_sync_service.dart';

void main() {
  // The cache also writes through to secure storage, which needs the binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await CalendarSyncService.clearGoogleImportTokenCache();
    await CalendarSyncService.clearOutlookImportTokenCache();
  });

  group('Google import token cache', () {
    test('round-trips a cached token', () async {
      final expiry = DateTime.now().add(const Duration(hours: 1));
      await CalendarSyncService.cacheGoogleImportToken(
        token: 'ya29.test-access-token',
        expiry: expiry,
        userEmail: 'someone@example.com',
      );

      final cached = await CalendarSyncService.getCachedGoogleImportPayload();
      expect(cached, isNotNull);
      expect(cached!['token'], 'ya29.test-access-token');
      expect(cached['userEmail'], 'someone@example.com');
    });

    test('clearing discards the token so it cannot be reused', () async {
      await CalendarSyncService.cacheGoogleImportToken(
        token: 'ya29.test-access-token',
        expiry: DateTime.now().add(const Duration(hours: 1)),
        userEmail: 'someone@example.com',
      );
      expect(
        await CalendarSyncService.getCachedGoogleImportPayload(),
        isNotNull,
        reason: 'precondition: a token is cached',
      );

      await CalendarSyncService.clearGoogleImportTokenCache();

      expect(
        await CalendarSyncService.getCachedGoogleImportPayload(),
        isNull,
        reason: 'after disconnecting the account no credential may remain',
      );
    });
  });
}
